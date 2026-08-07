// Command max-wechat-bridge runs on the Windows host beside a WeChat client
// hooked by aixed/WeChat-Hook, and gives max the two things that hook's HTTP
// API can only do through the local filesystem.
//
// The hook sends an image by reading a path on this machine's own disk, and it
// decrypts a received image the same way. max runs elsewhere, so it has no way
// to put a file there or to read one back. This bridge is the file end of both
// operations and nothing more: it is not a general proxy for the hook's API.
//
// Two properties are deliberate rather than incidental.
//
// Outbound is allowlisted. The hook will send to any wxid it is given, so a
// bridge that forwarded an arbitrary target would be a "message anyone on this
// WeChat account" service for whoever reached the port. Targets not configured
// here are refused before the hook ever sees them.
//
// Inbound fails closed. A received image is matched to the callback that
// announced it by decrypting candidates and comparing MD5 against the digest
// WeChat published, never by guessing from arrival time alone. No match means
// no image, which leaves max degrading exactly as it does today. The failure
// this rules out — quietly attaching a different image from the same chat — is
// far worse than the feature being absent.
package main

import (
	"bytes"
	"crypto/md5"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type server struct {
	token         string
	hookURL       string
	allowedTarget map[string]bool
	stagingRoot   string
	attachRoots   []string
	maxBytes      int64
	fetchWindow   time.Duration
	maxCandidates int
	client        *http.Client
}

func (s *server) authorized(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if len(provided) != len(s.token) || subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// hookCall posts JSON to one of the hook's endpoints. Every request opens its
// own connection: the DLL's embedded HTTP server abandons pooled connections
// without answering, which max already worked around on its own side.
func (s *server) hookCall(endpoint string, payload any) (map[string]any, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequest(http.MethodPost, strings.TrimRight(s.hookURL, "/")+endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Close = true
	response, err := s.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("hook %s: HTTP %d: %s", endpoint, response.StatusCode, truncate(string(raw), 200))
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("hook %s: unparseable response: %s", endpoint, truncate(string(raw), 200))
	}
	return decoded, nil
}

// stage writes bytes to a fresh file under the staging root and returns its
// path plus a remover. The file exists only across the send that reads it:
// leaving user images on the host's disk is not this bridge's business.
func (s *server) stage(data []byte, extension string) (string, func(), error) {
	if err := os.MkdirAll(s.stagingRoot, 0o700); err != nil {
		return "", nil, err
	}
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", nil, err
	}
	path := filepath.Join(s.stagingRoot, "max-"+hex.EncodeToString(random)+extension)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", nil, err
	}
	return path, func() { _ = os.Remove(path) }, nil
}

func (s *server) sendImage(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	target := strings.TrimSpace(request.URL.Query().Get("to"))
	if !s.allowedTarget[target] {
		// Same answer for "not configured" and "malformed": the caller learns
		// nothing about which targets exist on this account.
		http.Error(w, "target not allowlisted", http.StatusForbidden)
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, request.Body, s.maxBytes))
	if err != nil {
		http.Error(w, "image exceeds the configured size limit", http.StatusRequestEntityTooLarge)
		return
	}
	if len(data) == 0 {
		http.Error(w, "empty image", http.StatusBadRequest)
		return
	}
	path, remove, err := s.stage(data, imageExtension(data))
	if err != nil {
		log.Printf("send-image: staging failed: %v", err)
		http.Error(w, "staging unavailable", http.StatusInternalServerError)
		return
	}
	defer remove()

	decoded, err := s.hookCall("/SendImgMsg", map[string]any{"wxidorgid": target, "path": path})
	if err != nil {
		log.Printf("send-image: %v", err)
		http.Error(w, "hook unreachable", http.StatusBadGateway)
		return
	}
	if code, ok := jsonInt(decoded["ret"]); !ok || code != 0 {
		log.Printf("send-image: hook ret=%v retmsg=%v", decoded["ret"], decoded["retmsg"])
		http.Error(w, "hook refused the image", http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "byte_size": len(data)})
}

// fetchRequest names a received image by the digests WeChat published for it in
// the message payload, not by any path: the callback carries no path, and the
// hook's database module cannot supply one on WeChat 4.x.
type fetchRequest struct {
	MD5       string `json:"md5"`
	OriginMD5 string `json:"origin_md5"`
	Length    int64  `json:"length"`
	HDLength  int64  `json:"hd_length"`
	AfterUnix int64  `json:"after_unix"`
}

func (s *server) fetchImage(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	var wanted fetchRequest
	if err := json.NewDecoder(io.LimitReader(request.Body, 1<<16)).Decode(&wanted); err != nil {
		http.Error(w, "malformed request", http.StatusBadRequest)
		return
	}
	digests := map[string]bool{}
	for _, digest := range []string{wanted.MD5, wanted.OriginMD5} {
		if normalized := strings.ToLower(strings.TrimSpace(digest)); len(normalized) == 32 {
			digests[normalized] = true
		}
	}
	if len(digests) == 0 {
		// Without a digest there is nothing to verify against, and an
		// unverified match is the one outcome this endpoint exists to avoid.
		http.Error(w, "md5 or origin_md5 is required", http.StatusBadRequest)
		return
	}

	after := time.Now().Add(-s.fetchWindow)
	if wanted.AfterUnix > 0 {
		if announced := time.Unix(wanted.AfterUnix, 0); announced.After(after) {
			after = announced
		}
	}
	// A little slack before the announced time: the file is written as the
	// message arrives, and the two clocks are not the same clock.
	candidates := s.candidates(after.Add(-2*time.Minute), wanted.Length, wanted.HDLength)
	for _, candidate := range candidates {
		data, digest, err := s.decodeCandidate(candidate.path)
		if err != nil {
			continue
		}
		if digests[digest] {
			w.Header().Set("Content-Type", "image/jpeg")
			w.Header().Set("X-Image-MD5", digest)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(data)
			return
		}
	}
	log.Printf("fetch-image: no candidate matched (%d examined)", len(candidates))
	http.Error(w, "no matching image", http.StatusNotFound)
}

type candidate struct {
	path     string
	size     int64
	distance int64
	modified time.Time
}

// candidates lists recently written files under the configured roots, ordered
// so the likeliest is decrypted first: closest to an announced byte length,
// then newest. The order is an optimisation only — correctness rests entirely
// on the MD5 comparison, so a bad guess costs one decrypt and nothing else.
func (s *server) candidates(after time.Time, lengths ...int64) []candidate {
	var found []candidate
	for _, root := range s.attachRoots {
		_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				// An unreadable subtree is normal here: WeChat keeps files open
				// and locks some of them. Skip it rather than abandoning the walk.
				if entry != nil && entry.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			info, err := entry.Info()
			if err != nil || info.ModTime().Before(after) || info.Size() == 0 {
				return nil
			}
			distance := int64(-1)
			for _, length := range lengths {
				if length <= 0 {
					continue
				}
				delta := info.Size() - length
				if delta < 0 {
					delta = -delta
				}
				if distance < 0 || delta < distance {
					distance = delta
				}
			}
			if distance < 0 {
				distance = 1 << 62
			}
			found = append(found, candidate{path: path, size: info.Size(), distance: distance, modified: info.ModTime()})
			return nil
		})
	}
	sort.Slice(found, func(a, b int) bool {
		if found[a].distance != found[b].distance {
			return found[a].distance < found[b].distance
		}
		return found[a].modified.After(found[b].modified)
	})
	if len(found) > s.maxCandidates {
		log.Printf("fetch-image: %d candidates in window, examining the closest %d", len(found), s.maxCandidates)
		found = found[:s.maxCandidates]
	}
	return found
}

// decodeCandidate asks the hook to decrypt one stored image and returns the
// plaintext bytes with their MD5. The decrypted copy never outlives the call.
func (s *server) decodeCandidate(source string) ([]byte, string, error) {
	destination, remove, err := s.stage(nil, ".jpg")
	if err != nil {
		return nil, "", err
	}
	defer remove()
	if _, err := s.hookCall("/Decode_Pic", map[string]any{"src_path": source, "dst_path": destination}); err != nil {
		return nil, "", err
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		return nil, "", err
	}
	if len(data) == 0 {
		return nil, "", errors.New("decoded to an empty file")
	}
	sum := md5.Sum(data)
	return data, hex.EncodeToString(sum[:]), nil
}

func (s *server) health(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	status := map[string]any{"ok": true, "targets": len(s.allowedTarget), "attach_roots": s.attachRoots}
	// GetSelfProfile is the cheapest call that proves the DLL is loaded into a
	// running client. /QueryDB/status looks like the obvious probe and is not
	// one: on WeChat 4.x it answers IsLogin:0 while plainly logged in.
	if profile, err := s.hookCall("/GetSelfProfile", map[string]any{}); err != nil {
		status["ok"] = false
		status["hook_error"] = err.Error()
	} else {
		status["hook"] = "reachable"
		_ = profile
	}
	code := http.StatusOK
	if status["ok"] == false {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, status)
}

func writeJSON(w http.ResponseWriter, code int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(payload)
}

func jsonInt(value any) (int64, bool) {
	switch typed := value.(type) {
	case float64:
		return int64(typed), true
	case string:
		parsed, err := strconv.ParseInt(typed, 10, 64)
		return parsed, err == nil
	}
	return 0, false
}

// imageExtension picks the suffix from the bytes themselves. WeChat decides how
// to treat an attachment by extension, and the sender's filename never reaches
// this bridge.
func imageExtension(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return ".jpg"
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return ".png"
	case bytes.HasPrefix(data, []byte("GIF8")):
		return ".gif"
	case len(data) > 12 && bytes.Equal(data[0:4], []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")):
		return ".webp"
	default:
		return ".jpg"
	}
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "…"
}

func splitList(raw string) []string {
	var out []string
	for _, piece := range strings.Split(raw, ",") {
		if trimmed := strings.TrimSpace(piece); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func main() {
	listen := os.Getenv("WECHAT_BRIDGE_LISTEN")
	token := os.Getenv("WECHAT_BRIDGE_TOKEN")
	targets := splitList(os.Getenv("WECHAT_ALLOWED_TARGETS"))
	if listen == "" || token == "" || len(targets) == 0 {
		log.Fatal("WECHAT_BRIDGE_LISTEN (a Tailscale address), WECHAT_BRIDGE_TOKEN and WECHAT_ALLOWED_TARGETS are required")
	}
	hookURL := os.Getenv("WECHAT_HOOK_URL")
	if hookURL == "" {
		hookURL = "http://127.0.0.1:30001"
	}
	stagingRoot := os.Getenv("WECHAT_STAGING_DIR")
	if stagingRoot == "" {
		stagingRoot = filepath.Join(os.TempDir(), "max-wechat-bridge")
	}
	attachRoots := splitList(os.Getenv("WECHAT_ATTACH_ROOTS"))
	maxBytes := int64(32 * 1024 * 1024)
	if configured := os.Getenv("WECHAT_MAX_IMAGE_BYTES"); configured != "" {
		parsed, err := strconv.ParseInt(configured, 10, 64)
		if err != nil || parsed <= 0 {
			log.Fatal("WECHAT_MAX_IMAGE_BYTES must be a positive integer")
		}
		maxBytes = parsed
	}
	fetchWindow := 10 * time.Minute
	if configured := os.Getenv("WECHAT_FETCH_WINDOW_SECONDS"); configured != "" {
		parsed, err := strconv.Atoi(configured)
		if err != nil || parsed <= 0 {
			log.Fatal("WECHAT_FETCH_WINDOW_SECONDS must be a positive integer")
		}
		fetchWindow = time.Duration(parsed) * time.Second
	}
	// Staging files are only ever valid inside the request that wrote them, so
	// anything here is debris from a kill and cannot be useful to anyone.
	if entries, err := os.ReadDir(stagingRoot); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasPrefix(entry.Name(), "max-") {
				_ = os.Remove(filepath.Join(stagingRoot, entry.Name()))
			}
		}
	}

	allowed := map[string]bool{}
	for _, target := range targets {
		allowed[target] = true
	}
	s := &server{
		token:         token,
		hookURL:       hookURL,
		allowedTarget: allowed,
		stagingRoot:   stagingRoot,
		attachRoots:   attachRoots,
		maxBytes:      maxBytes,
		fetchWindow:   fetchWindow,
		maxCandidates: 60,
		client:        &http.Client{Timeout: 30 * time.Second},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.authorized(s.health))
	mux.HandleFunc("/send-image", s.authorized(s.sendImage))
	mux.HandleFunc("/fetch-image", s.authorized(s.fetchImage))

	if len(attachRoots) == 0 {
		log.Print("WECHAT_ATTACH_ROOTS is unset: /send-image works, /fetch-image will match nothing")
	}
	log.Printf("max-wechat-bridge listening on %s (hook %s, %d target(s))", listen, hookURL, len(allowed))
	server := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(server.ListenAndServe())
}
