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
	"os/exec"
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
	fetchGrace    time.Duration
	maxCandidates int
	client        *http.Client
	// The two per-installation constants that open a stored image. The XOR
	// byte is optional: left unset it is rediscovered per file against the
	// digest WeChat published, which is correct but 256 times the work.
	imageKey []byte
	imageXOR *byte
	ffmpeg   string
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

// stagePath reserves an unused path under the staging root and returns it with
// a remover. Nothing is created: an output path handed to the hook must not
// exist yet, because a writer that opens its destination with CREATE_NEW fails
// on a file this bridge helpfully pre-made.
func (s *server) stagePath(extension string) (string, func(), error) {
	if err := os.MkdirAll(s.stagingRoot, 0o700); err != nil {
		return "", nil, err
	}
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", nil, err
	}
	path := filepath.Join(s.stagingRoot, "max-"+hex.EncodeToString(random)+extension)
	return path, func() { _ = os.Remove(path) }, nil
}

// stage writes bytes to a fresh file under the staging root and returns its
// path plus a remover. The file exists only across the send that reads it:
// leaving user images on the host's disk is not this bridge's business.
func (s *server) stage(data []byte, extension string) (string, func(), error) {
	path, remove, err := s.stagePath(extension)
	if err != nil {
		return "", nil, err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		remove()
		return "", nil, err
	}
	return path, remove, nil
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
	if len(digests) == 0 && wanted.Length <= 0 && wanted.HDLength <= 0 {
		// Something must identify the image, or a match cannot be verified —
		// and an unverified match is the one outcome this endpoint exists to
		// avoid.
		http.Error(w, "md5, origin_md5 or a byte length is required", http.StatusBadRequest)
		return
	}

	after := time.Now().Add(-s.fetchWindow)
	if wanted.AfterUnix > 0 {
		if announced := time.Unix(wanted.AfterUnix, 0); announced.After(after) {
			after = announced
		}
	}
	// The caller asks the moment the callback lands, and WeChat is still
	// writing the file around then — a half-written one has the wrong length
	// and is correctly refused, so the first look can miss an image that
	// arrives a second later. Retrying costs nothing but the wait: identity is
	// verified on every attempt, so a later look cannot return a wrong
	// picture, only a right one that was not there yet.
	deadline := time.Now().Add(s.fetchGrace)
	for attempt := 1; ; attempt++ {
		image, contentType, digest, how, err := s.findImage(after, wanted, digests)
		if err != nil {
			http.Error(w, "image found but not convertible", http.StatusBadGateway)
			return
		}
		if image != nil {
			if attempt > 1 {
				log.Printf("fetch-image: matched on attempt %d by %s", attempt, how)
			}
			w.Header().Set("Content-Type", contentType)
			w.Header().Set("X-Image-MD5", digest)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(image)
			return
		}
		if !time.Now().Before(deadline) {
			log.Printf("fetch-image: gave up after %d attempts over %s", attempt, s.fetchGrace)
			break
		}
		time.Sleep(fetchPollInterval)
	}
	http.Error(w, "no matching image", http.StatusNotFound)
}

// findImage runs one pass over the stored files. A nil image with a nil error
// means nothing matched yet, which is a reason to look again rather than a
// failure; an error means the match was right and the conversion was not.
func (s *server) findImage(after time.Time, wanted fetchRequest, digests map[string]bool) ([]byte, string, string, string, error) {
	// A little slack before the announced time: the file is written as the
	// message arrives, and the two clocks are not the same clock.
	candidates := s.candidates(after.Add(-2*time.Minute), wanted.Length, wanted.HDLength)
	// A miss has two very different causes — every decrypt failed, or they all
	// succeeded and simply digest differently — and reporting only the count
	// cannot tell them apart. Each outcome is named so one run settles it.
	decoded, failed := 0, 0
	for _, candidate := range candidates {
		data, digest, err := s.decodeCandidate(candidate.path)
		if err != nil {
			failed++
			log.Printf("fetch-image:   %-44s %8d B  decrypt failed: %v", filepath.Base(candidate.path), candidate.size, err)
			continue
		}
		decoded++
		how, ok := identifies(data, digest, digests, wanted)
		if !ok {
			log.Printf("fetch-image:   %-44s %8d B  -> %d B md5=%s, not the one", filepath.Base(candidate.path), candidate.size, len(data), digest)
			continue
		}
		image, contentType, err := toJPEG(s.ffmpeg, data)
		if err != nil {
			// Identified but unusable is worth shouting about: the match was
			// right and the conversion is what let it down.
			log.Printf("fetch-image: matched %s by %s but could not convert: %v", filepath.Base(candidate.path), how, err)
			return nil, "", "", how, err
		}
		log.Printf("fetch-image: matched %s by %s, %d B -> %d B", filepath.Base(candidate.path), how, len(data), len(image))
		return image, contentType, digest, how, nil
	}
	log.Printf("fetch-image: no match yet (%d examined: %d decrypted, %d undecryptable); wanted digests=%v length=%d hd=%d",
		len(candidates), decoded, failed, keys(digests), wanted.Length, wanted.HDLength)
	return nil, "", "", "", nil
}

// identifies decides whether a decrypted file is the image that was asked for,
// and says which evidence settled it.
//
// The published digest is the strongest answer but not a sufficient one: of
// seven real images only two matched theirs, exactly the two whose payload
// carried no hdlength. Where an HD version exists that digest describes
// something other than the mid-size file on disk. What held on all seven is
// the decrypted length equalling an announced length, and byte lengths that
// exact do not collide by accident within a few minutes of one chat.
//
// The magic check is what keeps that honest: a length alone could match a file
// that merely happens to be the right size, so the content must also be an
// image WeChat would have stored.
func identifies(plain []byte, digest string, digests map[string]bool, wanted fetchRequest) (string, bool) {
	if digests[digest] {
		return "digest", true
	}
	size := int64(len(plain))
	if size <= 0 {
		return "", false
	}
	if size != wanted.Length && size != wanted.HDLength {
		return "", false
	}
	if !isWXGF(plain) && !isJPEG(plain) {
		return "", false
	}
	return "length+magic", true
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

// decodeCandidate decrypts one stored image in this process and returns the
// plaintext with its MD5. Nothing is written to disk and the hook is not
// involved: its /Decode_Pic answers {"ret":0,"retmsg":"success"} on WeChat 4.x
// and produces no file at all, the same way its database module reports a
// plainly logged-in client as logged out.
func (s *server) decodeCandidate(source string) ([]byte, string, error) {
	if len(s.imageKey) == 0 {
		return nil, "", errors.New("no image key configured; run with -find-key")
	}
	if s.imageXOR == nil {
		// Identity is now settled after decryption rather than during it, so
		// there is no longer an oracle to search the XOR byte against here.
		// It is derived at startup from any thumbnail, or pinned in config.
		return nil, "", errors.New("no XOR byte known; set WECHAT_IMAGE_XOR")
	}
	raw, err := os.ReadFile(source)
	if err != nil {
		return nil, "", err
	}
	data, _, digest, err := decryptDat(raw, s.imageKey, s.imageXOR, nil)
	if err != nil {
		return nil, "", err
	}
	if len(data) == 0 {
		return nil, "", errors.New("decrypted to nothing")
	}
	return data, digest, nil
}

// discoverXORKey reads any thumbnail under the configured roots and takes the
// XOR byte from its JPEG ending, so an operator who ran -find-key once does not
// have to carry the value around by hand.
func discoverXORKey(roots []string) (byte, bool) {
	for _, root := range roots {
		var found byte
		var ok bool
		_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() || !strings.HasSuffix(path, "_t.dat") {
				return nil
			}
			raw, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil
			}
			if value, deriveErr := deriveXORKey(raw); deriveErr == nil {
				found, ok = value, true
				return filepath.SkipAll
			}
			return nil
		})
		if ok {
			return found, true
		}
	}
	return 0, false
}

// scan reports what /fetch-image would examine, decrypting nothing. When a
// match fails this answers the question underneath it: are the right files
// even in view? A count of zero means the configured roots or the time window
// are wrong, and no amount of digest work will help.
func (s *server) scan(w http.ResponseWriter, request *http.Request) {
	after := time.Now().Add(-s.fetchWindow)
	if raw := request.URL.Query().Get("after_unix"); raw != "" {
		if parsed, err := strconv.ParseInt(raw, 10, 64); err == nil && parsed > 0 {
			after = time.Unix(parsed, 0)
		}
	}
	found := s.candidates(after.Add(-2 * time.Minute))
	rows := make([]map[string]any, 0, len(found))
	for _, entry := range found {
		rows = append(rows, map[string]any{
			"path":     entry.path,
			"size":     entry.size,
			"modified": entry.modified.Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"roots":      s.attachRoots,
		"since":      after.Format(time.RFC3339),
		"count":      len(found),
		"candidates": rows,
	})
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

// Short enough that a picture is not perceptibly late, long enough that each
// pass is a real look rather than a spin.
const fetchPollInterval = 750 * time.Millisecond

func writeJSON(w http.ResponseWriter, code int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(payload)
}

func keys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for key := range set {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
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

// runFindKey performs the one-time hunt for this installation's image keys.
// It is a subcommand rather than a startup step because it reads another
// process's memory, which is a thing to do deliberately and once — the keys it
// prints stay valid until WeChat is reinstalled.
func runFindKey(args []string) {
	if len(args) < 1 {
		log.Fatal("usage: max-wechat-bridge -find-key <sample.dat> [<md5> <originsourcemd5>]\n" +
			"       a *_t.dat thumbnail needs no digests: it is verified as a JPEG")
	}
	sample, err := os.ReadFile(args[0])
	if err != nil {
		log.Fatal(err)
	}
	layout, err := parseDat(sample)
	if err != nil {
		log.Fatalf("%s: %v", filepath.Base(args[0]), err)
	}
	log.Printf("find-key: %s is a V2 container (aes=%d xor=%d plaintext=%d)",
		filepath.Base(args[0]), layout.aesSize, layout.xorSize, layout.plainBytes)

	want := map[string]bool{}
	for _, digest := range args[1:] {
		if normalized := strings.ToLower(strings.TrimSpace(digest)); len(normalized) == 32 {
			want[normalized] = true
		}
	}
	accept := digestAccept(want)
	if accept != nil {
		log.Printf("find-key: verifying against %d published digest(s)", len(want))
	} else {
		// A thumbnail is the better sample anyway: WeChat publishes no digest
		// for one, but keeps it JPEG, and JPEG is a shape this can check. The
		// full image is HEVC and may sit in a WeChat-only wrapper whose magic
		// nothing here would recognise — a correct key would then be thrown
		// away for producing something unrecognisable.
		log.Printf("find-key: no digests given, verifying JPEG structure (use a *_t.dat thumbnail)")
		accept = jpegAccept
	}
	// 16 first because that is what this client uses; 32 covers an AES-256
	// build rather than assuming the one sample we have is the whole world.
	for _, size := range []int{16, 32} {
		key, xorByte, findErr := findImageKey(sample, accept, size)
		if findErr != nil {
			log.Printf("find-key: no %d-byte key: %v", size, findErr)
			continue
		}
		log.Printf("find-key: verified against the digest WeChat published for this image")
		fmt.Printf("\nWECHAT_IMAGE_AES_KEY=%s\nWECHAT_IMAGE_XOR=%02x\n\n", string(key), xorByte)
		return
	}
	log.Fatal("find-key: no key found")
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "-find-key" {
		runFindKey(os.Args[2:])
		return
	}
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
	// How long to keep re-looking for a file WeChat has not finished writing.
	// The caller asks the instant the message lands, so the first look often
	// precedes the bytes; this is the only reason a correct request misses.
	fetchGrace := 20 * time.Second
	if configured := os.Getenv("WECHAT_FETCH_GRACE_SECONDS"); configured != "" {
		parsed, err := strconv.Atoi(configured)
		if err != nil || parsed < 0 {
			log.Fatal("WECHAT_FETCH_GRACE_SECONDS must be a non-negative integer")
		}
		fetchGrace = time.Duration(parsed) * time.Second
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

	var imageKey []byte
	if configured := os.Getenv("WECHAT_IMAGE_AES_KEY"); configured != "" {
		imageKey = []byte(configured)
		if len(imageKey) != 16 && len(imageKey) != 32 {
			log.Fatal("WECHAT_IMAGE_AES_KEY must be 16 or 32 characters (WeChat carries it as ASCII)")
		}
	}
	var imageXOR *byte
	if configured := os.Getenv("WECHAT_IMAGE_XOR"); configured != "" {
		parsed, err := strconv.ParseUint(strings.TrimPrefix(strings.ToLower(configured), "0x"), 16, 8)
		if err != nil {
			log.Fatal("WECHAT_IMAGE_XOR must be one hex byte, e.g. c0")
		}
		value := byte(parsed)
		imageXOR = &value
	} else if value, ok := discoverXORKey(attachRoots); ok {
		log.Printf("XOR key 0x%02X derived from a stored thumbnail", value)
		imageXOR = &value
	}
	ffmpegPath := os.Getenv("WECHAT_FFMPEG")
	if ffmpegPath == "" {
		ffmpegPath = "ffmpeg"
	}
	// A full-size image is HEVC inside WeChat's own wrapper, so without this
	// only thumbnails can be served. Saying so at startup beats discovering it
	// on the first image that matters.
	if _, err := exec.LookPath(ffmpegPath); err != nil {
		log.Printf("%s not found: full-size images cannot be converted, only thumbnails", ffmpegPath)
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
		fetchGrace:    fetchGrace,
		maxCandidates: 60,
		client:        &http.Client{Timeout: 30 * time.Second},
		imageKey:      imageKey,
		imageXOR:      imageXOR,
		ffmpeg:        ffmpegPath,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.authorized(s.health))
	mux.HandleFunc("/send-image", s.authorized(s.sendImage))
	mux.HandleFunc("/fetch-image", s.authorized(s.fetchImage))
	mux.HandleFunc("/scan", s.authorized(s.scan))

	if len(attachRoots) == 0 {
		log.Print("WECHAT_ATTACH_ROOTS is unset: /send-image works, /fetch-image will match nothing")
	}
	log.Printf("max-wechat-bridge listening on %s (hook %s, %d target(s))", listen, hookURL, len(allowed))
	server := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(server.ListenAndServe())
}
