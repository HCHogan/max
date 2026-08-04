// imsg-bridge is a deliberately small authenticated transport around
// `imsg rpc`. It is intended to run on the Mac that owns chat.db and bind only
// to that Mac's Tailscale address. Max never receives filesystem access.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"
)

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type runner struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	pending  sync.Map // request id string -> chan rpcResponse
	watchers sync.Map // subscription number -> chan json.RawMessage
	writeMu  sync.Mutex
	nextID   atomic.Uint64
}

func startRunner(path string) (*runner, error) {
	cmd := exec.Command(path, "rpc")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	r := &runner{cmd: cmd, stdin: stdin}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go r.readLoop(stdout)
	return r, nil
}

func (r *runner) readLoop(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		var response rpcResponse
		if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
			log.Printf("imsg emitted invalid JSON: %v", err)
			continue
		}
		if len(response.ID) != 0 {
			id := strings.Trim(string(response.ID), `"`)
			if waiting, ok := r.pending.LoadAndDelete(id); ok {
				waiting.(chan rpcResponse) <- response
			}
			continue
		}
		if response.Method == "message" {
			var params struct {
				Subscription int             `json:"subscription"`
				Message      json.RawMessage `json:"message"`
			}
			if json.Unmarshal(response.Params, &params) == nil {
				if target, ok := r.watchers.Load(params.Subscription); ok {
					select {
					case target.(chan json.RawMessage) <- params.Message:
					default:
						log.Printf("watch subscriber %d is slow; dropping wakeup subscription", params.Subscription)
						r.watchers.Delete(params.Subscription)
					}
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("imsg rpc stdout failed: %v", err)
	}
	r.pending.Range(func(key, value any) bool {
		value.(chan rpcResponse) <- rpcResponse{Error: &rpcError{Code: -32000, Message: "imsg rpc exited"}}
		r.pending.Delete(key)
		return true
	})
}

func (r *runner) call(ctx context.Context, method string, params json.RawMessage) (rpcResponse, error) {
	id := strconv.FormatUint(r.nextID.Add(1), 10)
	request := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if len(params) != 0 {
		request["params"] = params
	}
	line, err := json.Marshal(request)
	if err != nil {
		return rpcResponse{}, err
	}
	waiting := make(chan rpcResponse, 1)
	r.pending.Store(id, waiting)
	r.writeMu.Lock()
	_, writeErr := r.stdin.Write(append(line, '\n'))
	r.writeMu.Unlock()
	if writeErr != nil {
		r.pending.Delete(id)
		return rpcResponse{}, writeErr
	}
	select {
	case response := <-waiting:
		return response, nil
	case <-ctx.Done():
		r.pending.Delete(id)
		return rpcResponse{}, ctx.Err()
	}
}

type server struct {
	runner              *runner
	imsgPath            string
	nativeReplyProbe    func() bool
	token               string
	dbPath              string
	sqlitePath          string
	attachmentRoot      string
	outboundRoot        string
	allowedChatGUID     string
	allowedChatIDs      sync.Map // chat id string -> struct{}
	attachments         sync.Map // opaque attachment id -> attachmentRecord
	outboundAttachments sync.Map // one-shot upload id -> attachmentRecord
	maxAttachmentBytes  int64
}

type attachmentRecord struct {
	path        string
	contentType string
	name        string
	size        int64
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

func (s *server) rpc(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	body := http.MaxBytesReader(w, request.Body, 2*1024*1024)
	var input struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.NewDecoder(body).Decode(&input); err != nil || input.Method == "" {
		http.Error(w, "invalid RPC request", http.StatusBadRequest)
		return
	}
	if err := s.authorizeRPC(input.Method, input.Params); err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	prepared, cleanup, err := s.prepareRPC(input.Method, input.Params)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	defer cleanup()
	response, err := s.runner.call(request.Context(), input.Method, prepared)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if response.Error != nil {
		w.WriteHeader(http.StatusBadGateway)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": response.Error})
		return
	}
	result, err := s.sanitizeRPCResult(input.Method, input.Params, response.Result)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	_, _ = w.Write(result)
}

func (s *server) authorizeRPC(method string, raw json.RawMessage) error {
	switch method {
	case "chats.list":
		return nil
	case "messages.after":
		var params struct {
			ChatID int64 `json:"chat_id"`
		}
		if json.Unmarshal(raw, &params) != nil || !s.chatIDAllowed(params.ChatID) {
			return errors.New("messages.after chat is not allowlisted")
		}
		return nil
	case "send":
		var params struct {
			ChatGUID string `json:"chat_guid"`
			File     string `json:"file"`
			ReplyTo  string `json:"reply_to"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ChatGUID != s.allowedChatGUID {
			return errors.New("send chat is not allowlisted")
		}
		if params.ReplyTo != "" {
			if len(params.ReplyTo) > 256 {
				return errors.New("send reply_to must be bounded")
			}
			if !s.supportsNativeReplies() {
				return errors.New("send reply_to requires the active IMCore helper")
			}
		}
		if params.File != "" {
			id := strings.TrimPrefix(params.File, "upload:")
			if id == params.File || len(id) != sha256.Size*2 {
				return errors.New("send file must be an opaque bridge upload")
			}
			if _, ok := s.outboundAttachments.Load(id); !ok {
				return errors.New("send file upload is missing or expired")
			}
		}
		return nil
	case "message.send_status":
		var params struct {
			GUID string `json:"guid"`
		}
		if json.Unmarshal(raw, &params) != nil {
			return errors.New("message.send_status requires guid")
		}
		if params.GUID == "" || len(params.GUID) > 256 {
			return errors.New("message.send_status requires a bounded guid")
		}
		return nil
	default:
		return fmt.Errorf("imsg RPC method %q is not exposed", method)
	}
}

func (s *server) prepareRPC(method string, raw json.RawMessage) (json.RawMessage, func(), error) {
	noop := func() {}
	if method != "send" {
		return raw, noop, nil
	}
	var params map[string]any
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, noop, errors.New("invalid send params")
	}
	// Once the optional helper is active, imsg otherwise routes every send
	// through IMCore. Keep ordinary sends on the public AppleScript transport;
	// IMCore is needed only to create a native inline-reply relation.
	replyTo, _ := params["reply_to"].(string)
	if replyTo == "" {
		params["transport"] = "applescript"
	} else {
		params["transport"] = "bridge"
	}
	fileValue, _ := params["file"].(string)
	cleanup := noop
	if fileValue != "" {
		id := strings.TrimPrefix(fileValue, "upload:")
		value, ok := s.outboundAttachments.Load(id)
		if !ok || id == fileValue {
			return nil, noop, errors.New("send file upload is missing or expired")
		}
		record := value.(attachmentRecord)
		params["file"] = record.path
		cleanup = func() {
			s.outboundAttachments.Delete(id)
			if err := os.Remove(record.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				log.Printf("remove staged outbound attachment: %v", err)
			}
		}
	}
	prepared, err := json.Marshal(params)
	if err != nil {
		cleanup()
		return nil, noop, err
	}
	return prepared, cleanup, nil
}

func (s *server) sanitizeRPCResult(method string, paramsRaw, resultRaw json.RawMessage) (json.RawMessage, error) {
	switch method {
	case "chats.list":
		return s.filterChats(resultRaw)
	case "messages.after":
		return s.sanitizeMessages(resultRaw)
	case "send":
		var params struct {
			ReplyTo string `json:"reply_to"`
		}
		if err := json.Unmarshal(paramsRaw, &params); err != nil {
			return nil, fmt.Errorf("decode send params: %w", err)
		}
		var result map[string]any
		if err := json.Unmarshal(resultRaw, &result); err != nil {
			return nil, fmt.Errorf("decode send result: %w", err)
		}
		if params.ReplyTo == "" {
			return resultRaw, nil
		}
		// IMCore reports chat.lastSentMessage immediately after sending. That is
		// explicitly best-effort and can still identify the preceding message.
		// The later messages.after echo is the authoritative native GUID.
		delete(result, "guid")
		delete(result, "message_id")
		delete(result, "id")
		return json.Marshal(result)
	default:
		return resultRaw, nil
	}
}

func (s *server) filterChats(raw json.RawMessage) (json.RawMessage, error) {
	var result struct {
		Chats []map[string]any `json:"chats"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("decode chats.list result: %w", err)
	}
	filtered := make([]map[string]any, 0, 1)
	for _, chat := range result.Chats {
		guid, _ := chat["guid"].(string)
		if guid != s.allowedChatGUID {
			continue
		}
		chatID, ok := jsonInt64(chat["id"])
		if !ok || chatID <= 0 {
			return nil, errors.New("allowlisted chat has no positive id")
		}
		s.allowedChatIDs.Store(strconv.FormatInt(chatID, 10), struct{}{})
		filtered = append(filtered, chat)
	}
	return json.Marshal(map[string]any{"chats": filtered})
}

func (s *server) sanitizeMessages(raw json.RawMessage) (json.RawMessage, error) {
	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("decode messages.after result: %w", err)
	}
	messages, _ := result["messages"].([]any)
	messageByRowID := make(map[int64]map[string]any, len(messages))
	for _, value := range messages {
		message, ok := value.(map[string]any)
		if !ok {
			continue
		}
		chatID, ok := jsonInt64(message["chat_id"])
		if !ok || !s.chatIDAllowed(chatID) {
			return nil, errors.New("messages.after returned a non-allowlisted chat")
		}
		if rowID, ok := jsonInt64(message["id"]); ok && rowID > 0 {
			messageByRowID[rowID] = message
		}
		attachments, _ := message["attachments"].([]any)
		for _, attachmentValue := range attachments {
			attachment, ok := attachmentValue.(map[string]any)
			if !ok {
				continue
			}
			path, _ := attachment["path"].(string)
			if path == "" {
				path, _ = attachment["original_path"].(string)
			}
			// Current imsg calls the absolute source original_path and may
			// duplicate a tilde path in filename. Neither is public metadata.
			delete(attachment, "path")
			delete(attachment, "original_path")
			delete(attachment, "filename")
			if path == "" {
				continue
			}
			id, record, err := s.registerAttachment(path, attachment)
			if err != nil {
				attachment["unavailable"] = err.Error()
				continue
			}
			attachment["attachment_id"] = id
			attachment["byte_size"] = record.size
		}
	}
	mentions, err := s.confirmedMentionsForRows(messageByRowID)
	if err != nil {
		return nil, err
	}
	for rowID, handles := range mentions {
		if len(handles) > 0 {
			messageByRowID[rowID]["mentioned_handles"] = handles
		}
	}
	return json.Marshal(result)
}

// imsg returns only the rendered attributed text. The stable identity behind
// an iMessage mention remains in attributedBody, so enrich only allowlisted
// rows before the payload leaves the Mac. The blob itself never crosses the
// bridge and display names are never treated as identities.
func (s *server) confirmedMentionsForRows(messages map[int64]map[string]any) (map[int64][]string, error) {
	result := make(map[int64][]string)
	if len(messages) == 0 || s.dbPath == "" {
		return result, nil
	}
	rowIDs := make([]string, 0, len(messages))
	for rowID := range messages {
		rowIDs = append(rowIDs, strconv.FormatInt(rowID, 10))
	}
	query := fmt.Sprintf(
		"SELECT ROWID AS row_id, hex(attributedBody) AS attributed_body_hex FROM message WHERE ROWID IN (%s) AND attributedBody IS NOT NULL AND instr(CAST(attributedBody AS BLOB), CAST('%s' AS BLOB)) > 0",
		strings.Join(rowIDs, ","), confirmedMentionAttribute,
	)
	sqlitePath := s.sqlitePath
	if sqlitePath == "" {
		sqlitePath = "/usr/bin/sqlite3"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, sqlitePath, "-readonly", "-json", s.dbPath, query).Output()
	if err != nil {
		return nil, fmt.Errorf("read iMessage mention metadata: %w", err)
	}
	var rows []struct {
		RowID             int64  `json:"row_id"`
		AttributedBodyHex string `json:"attributed_body_hex"`
	}
	if len(bytes.TrimSpace(output)) == 0 {
		return result, nil
	}
	if err := json.Unmarshal(output, &rows); err != nil {
		return nil, fmt.Errorf("decode iMessage mention metadata: %w", err)
	}
	for _, row := range rows {
		if _, allowed := messages[row.RowID]; !allowed {
			continue
		}
		body, err := hex.DecodeString(row.AttributedBodyHex)
		if err != nil {
			return nil, fmt.Errorf("decode attributedBody for row %d: %w", row.RowID, err)
		}
		result[row.RowID] = confirmedMentionHandles(body)
	}
	return result, nil
}

const confirmedMentionAttribute = "__kIMMentionConfirmedMention"

func confirmedMentionHandles(body []byte) []string {
	marker := []byte(confirmedMentionAttribute)
	var handles []string
	for offset := 0; offset < len(body); {
		position := bytes.Index(body[offset:], marker)
		if position < 0 {
			break
		}
		start := offset + position + len(marker)
		limit := start + 96
		if limit > len(body) {
			limit = len(body)
		}
		for index := start; index < limit; index++ {
			candidate, ok := typedStreamStringAt(body, index)
			if !ok || !isIMessageHandle(candidate) {
				continue
			}
			if !containsString(handles, candidate) {
				handles = append(handles, candidate)
			}
			break
		}
		offset = start
	}
	return handles
}

func typedStreamStringAt(body []byte, index int) (string, bool) {
	if index >= len(body) {
		return "", false
	}
	prefixLength := 1
	length := int(body[index])
	switch body[index] {
	case 0x81:
		if index+1 >= len(body) {
			return "", false
		}
		prefixLength, length = 2, int(body[index+1])
	case 0x82:
		if index+2 >= len(body) {
			return "", false
		}
		prefixLength, length = 3, int(body[index+1])<<8|int(body[index+2])
	default:
		if body[index] >= 0x80 {
			return "", false
		}
	}
	start := index + prefixLength
	end := start + length
	if length == 0 || length > 320 || end > len(body) || !utf8.Valid(body[start:end]) {
		return "", false
	}
	return string(body[start:end]), true
}

func isIMessageHandle(value string) bool {
	if value == "" || strings.IndexFunc(value, func(r rune) bool { return r <= ' ' }) >= 0 {
		return false
	}
	if strings.HasPrefix(value, "+") && len(value) >= 7 {
		for _, char := range value[1:] {
			if char < '0' || char > '9' {
				return false
			}
		}
		return true
	}
	at := strings.IndexByte(value, '@')
	return at > 0 && at < len(value)-1
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if strings.EqualFold(value, target) {
			return true
		}
	}
	return false
}

func (s *server) registerAttachment(path string, metadata map[string]any) (string, attachmentRecord, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", attachmentRecord{}, fmt.Errorf("attachment unavailable: %w", err)
	}
	root, err := filepath.EvalSymlinks(s.attachmentRoot)
	if err != nil {
		return "", attachmentRecord{}, fmt.Errorf("attachment root unavailable: %w", err)
	}
	relative, err := filepath.Rel(root, resolved)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", attachmentRecord{}, errors.New("attachment is outside the Messages attachment root")
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return "", attachmentRecord{}, errors.New("attachment is not a regular file")
	}
	if info.Size() < 0 || info.Size() > s.maxAttachmentBytes {
		return "", attachmentRecord{}, errors.New("attachment exceeds the configured size limit")
	}
	digest := sha256.Sum256([]byte(resolved))
	id := hex.EncodeToString(digest[:])
	contentType, _ := metadata["mime_type"].(string)
	name, _ := metadata["transfer_name"].(string)
	record := attachmentRecord{path: resolved, contentType: contentType, name: name, size: info.Size()}
	s.attachments.Store(id, record)
	return id, record, nil
}

func jsonInt64(value any) (int64, bool) {
	switch number := value.(type) {
	case float64:
		return int64(number), number == float64(int64(number))
	case json.Number:
		parsed, err := number.Int64()
		return parsed, err == nil
	default:
		return 0, false
	}
}

func (s *server) chatIDAllowed(chatID int64) bool {
	_, ok := s.allowedChatIDs.Load(strconv.FormatInt(chatID, 10))
	return ok
}

func (s *server) watch(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	chatID, err := strconv.ParseInt(request.URL.Query().Get("chat_id"), 10, 64)
	if err != nil || chatID <= 0 || !s.chatIDAllowed(chatID) {
		http.Error(w, "allowlisted positive chat_id required", http.StatusBadRequest)
		return
	}
	since, err := strconv.ParseInt(request.URL.Query().Get("since_rowid"), 10, 64)
	if err != nil || since < 0 {
		http.Error(w, "non-negative since_rowid required", http.StatusBadRequest)
		return
	}
	params, _ := json.Marshal(map[string]any{
		"chat_id": chatID, "since_rowid": since, "attachments": true,
		"include_reactions": true, "debounce_ms": 500,
	})
	response, err := s.runner.call(request.Context(), "watch.subscribe", params)
	if err != nil || response.Error != nil {
		http.Error(w, "watch.subscribe failed", http.StatusBadGateway)
		return
	}
	var subscribed struct {
		Subscription int `json:"subscription"`
	}
	if json.Unmarshal(response.Result, &subscribed) != nil || subscribed.Subscription <= 0 {
		http.Error(w, "invalid watch subscription", http.StatusBadGateway)
		return
	}
	messages := make(chan json.RawMessage, 128)
	s.runner.watchers.Store(subscribed.Subscription, messages)
	defer func() {
		s.runner.watchers.Delete(subscribed.Subscription)
		params, _ := json.Marshal(map[string]any{"subscription": subscribed.Subscription})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = s.runner.call(ctx, "watch.unsubscribe", params)
	}()
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unavailable", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	flusher.Flush()
	timer := time.NewTimer(30 * time.Second)
	defer timer.Stop()
	for {
		select {
		case message, open := <-messages:
			if !open {
				return
			}
			if _, err := w.Write(append(message, '\n')); err != nil {
				return
			}
			flusher.Flush()
		case <-request.Context().Done():
			return
		case <-timer.C:
			// Force periodic durable messages.after reconciliation.
			return
		}
	}
}

func (s *server) health(w http.ResponseWriter, request *http.Request) {
	fingerprint, err := databaseFingerprint(s.dbPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok": true, "source_fingerprint": fingerprint, "allowed_chat_guid": s.allowedChatGUID,
		"capabilities": map[string]bool{"reply": s.supportsNativeReplies()},
	})
}

func (s *server) supportsNativeReplies() bool {
	if s.nativeReplyProbe != nil {
		return s.nativeReplyProbe()
	}
	ready, err := imsgNativeReplies(s.imsgPath)
	return err == nil && ready
}

func imsgNativeReplies(path string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, path, "status", "--json").Output()
	if err != nil {
		return false, fmt.Errorf("imsg status: %w", err)
	}
	return parseIMessageStatus(output)
}

func parseIMessageStatus(raw []byte) (bool, error) {
	var status struct {
		AdvancedFeatures bool `json:"advanced_features"`
		BridgeVersion    int  `json:"bridge_version"`
	}
	if err := json.Unmarshal(raw, &status); err != nil {
		return false, fmt.Errorf("decode imsg status: %w", err)
	}
	return status.AdvancedFeatures && status.BridgeVersion > 0, nil
}

func (s *server) attachment(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(request.URL.Path, "/attachment/")
	value, ok := s.attachments.Load(id)
	if !ok || len(id) != sha256.Size*2 {
		http.NotFound(w, request)
		return
	}
	record := value.(attachmentRecord)
	file, err := os.Open(record.path)
	if err != nil {
		http.NotFound(w, request)
		return
	}
	defer file.Close()
	if record.contentType != "" {
		w.Header().Set("Content-Type", record.contentType)
	}
	w.Header().Set("Content-Length", strconv.FormatInt(record.size, 10))
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filepath.Base(record.name)))
	http.ServeContent(w, request, record.name, time.Time{}, file)
}

func (s *server) outboundAttachment(w http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	name := filepath.Base(strings.TrimSpace(request.URL.Query().Get("filename")))
	if name == "." || name == "" || len(name) > 255 {
		name = "attachment"
	}
	contentType := strings.TrimSpace(request.URL.Query().Get("mime_type"))
	if len(contentType) > 255 {
		http.Error(w, "mime_type is too long", http.StatusBadRequest)
		return
	}
	body := http.MaxBytesReader(w, request.Body, s.maxAttachmentBytes)
	bytes, err := io.ReadAll(body)
	if err != nil {
		http.Error(w, "attachment exceeds the configured size limit", http.StatusRequestEntityTooLarge)
		return
	}
	if len(bytes) == 0 {
		http.Error(w, "empty attachment", http.StatusBadRequest)
		return
	}
	if err := os.MkdirAll(s.outboundRoot, 0o700); err != nil {
		http.Error(w, "outbound staging unavailable", http.StatusInternalServerError)
		return
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		http.Error(w, "random upload id unavailable", http.StatusInternalServerError)
		return
	}
	id := hex.EncodeToString(random)
	path := filepath.Join(s.outboundRoot, id+"-"+name)
	temporary, err := os.CreateTemp(s.outboundRoot, ".upload-*")
	if err != nil {
		http.Error(w, "outbound staging unavailable", http.StatusInternalServerError)
		return
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		http.Error(w, "secure staging failed", http.StatusInternalServerError)
		return
	}
	if _, err := temporary.Write(bytes); err != nil || temporary.Close() != nil {
		http.Error(w, "staging write failed", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		http.Error(w, "staging commit failed", http.StatusInternalServerError)
		return
	}
	committed = true
	s.outboundAttachments.Store(id, attachmentRecord{path: path, contentType: contentType, name: name, size: int64(len(bytes))})
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "upload_id": id, "byte_size": len(bytes)})
}

// The in-memory upload handles never survive a bridge restart, so their files
// cannot be used afterwards either. Remove only files created by this bridge;
// ignore directories and unrelated operator-owned files even when an
// IMSG_OUTBOUND_ROOT was configured too broadly.
func cleanOrphanedOutboundAttachments(root string) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !isBridgeOutboundFilename(entry.Name()) {
			continue
		}
		if err := os.Remove(filepath.Join(root, entry.Name())); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func isBridgeOutboundFilename(name string) bool {
	if strings.HasPrefix(name, ".upload-") {
		return true
	}
	dash := strings.IndexByte(name, '-')
	if dash != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(name[:dash])
	return err == nil
}

func databaseFingerprint(path string) (string, error) {
	// On macOS device/inode/birthtime remain stable across WAL writes but
	// change when chat.db is replaced or restored by file replacement.
	output, err := exec.Command("stat", "-f", "%d:%i:%B", path).Output()
	if err != nil {
		return "", fmt.Errorf("stat chat.db: %w", err)
	}
	hash := sha256.Sum256([]byte(strings.TrimSpace(string(output))))
	return hex.EncodeToString(hash[:]), nil
}

func main() {
	listen := os.Getenv("IMSG_BRIDGE_LISTEN")
	token := os.Getenv("IMSG_BRIDGE_TOKEN")
	allowedChatGUID := os.Getenv("IMSG_ALLOWED_CHAT_GUID")
	if listen == "" || token == "" || allowedChatGUID == "" {
		log.Fatal("IMSG_BRIDGE_LISTEN (a Tailscale address), IMSG_BRIDGE_TOKEN and IMSG_ALLOWED_CHAT_GUID are required")
	}
	imsgPath := os.Getenv("IMSG_PATH")
	if imsgPath == "" {
		imsgPath = "imsg"
	}
	dbPath := os.Getenv("IMSG_DB_PATH")
	if dbPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			log.Fatal(err)
		}
		dbPath = filepath.Join(home, "Library", "Messages", "chat.db")
	}
	sqlitePath := os.Getenv("IMSG_SQLITE_PATH")
	if sqlitePath == "" {
		sqlitePath = "/usr/bin/sqlite3"
	}
	attachmentRoot := os.Getenv("IMSG_ATTACHMENT_ROOT")
	if attachmentRoot == "" {
		attachmentRoot = filepath.Join(filepath.Dir(dbPath), "Attachments")
	}
	outboundRoot := os.Getenv("IMSG_OUTBOUND_ROOT")
	if outboundRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			log.Fatal(err)
		}
		outboundRoot = filepath.Join(home, "Library", "Caches", "max-imsg-bridge", "outbound")
	}
	if err := cleanOrphanedOutboundAttachments(outboundRoot); err != nil {
		log.Fatalf("clean orphaned outbound attachments: %v", err)
	}
	maxAttachmentBytes := int64(64 * 1024 * 1024)
	if configured := os.Getenv("IMSG_MAX_ATTACHMENT_BYTES"); configured != "" {
		parsed, err := strconv.ParseInt(configured, 10, 64)
		if err != nil || parsed <= 0 {
			log.Fatal("IMSG_MAX_ATTACHMENT_BYTES must be a positive integer")
		}
		maxAttachmentBytes = parsed
	}
	rpcRunner, err := startRunner(imsgPath)
	if err != nil {
		log.Fatal(err)
	}
	nativeReplies, statusErr := imsgNativeReplies(imsgPath)
	if statusErr != nil {
		log.Printf("native reply capability unavailable: %v", statusErr)
	}
	s := &server{
		runner: rpcRunner, imsgPath: imsgPath, token: token, dbPath: dbPath, sqlitePath: sqlitePath, attachmentRoot: attachmentRoot, outboundRoot: outboundRoot,
		allowedChatGUID: allowedChatGUID, maxAttachmentBytes: maxAttachmentBytes,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.authorized(s.health))
	mux.HandleFunc("/rpc", s.authorized(s.rpc))
	mux.HandleFunc("/watch", s.authorized(s.watch))
	mux.HandleFunc("/attachment/", s.authorized(s.attachment))
	mux.HandleFunc("/outbound-attachment", s.authorized(s.outboundAttachment))
	httpServer := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stopped
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
		_ = rpcRunner.stdin.Close()
		_ = rpcRunner.cmd.Wait()
	}()
	log.Printf("imsg bridge listening on %s (native_replies=%t)", listen, nativeReplies)
	if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
