package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFilterChatsRegistersOnlyAllowlistedChat(t *testing.T) {
	s := &server{allowedChatGUID: "iMessage;+;allowed"}
	raw := json.RawMessage(`{"chats":[{"id":7,"guid":"iMessage;+;allowed"},{"id":8,"guid":"iMessage;+;other"}]}`)

	filtered, err := s.filterChats(raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(filtered), "other") || !strings.Contains(string(filtered), "allowed") {
		t.Fatalf("unexpected filtered chats: %s", filtered)
	}
	if !s.chatIDAllowed(7) || s.chatIDAllowed(8) {
		t.Fatal("chat id allowlist did not match filtered result")
	}
}

func TestAuthorizeRPCConfinesMethodsAndTargets(t *testing.T) {
	s := &server{allowedChatGUID: "iMessage;+;allowed"}
	s.allowedChatIDs.Store("7", struct{}{})

	if err := s.authorizeRPC("messages.after", json.RawMessage(`{"chat_id":7}`)); err != nil {
		t.Fatalf("allowlisted catchup rejected: %v", err)
	}
	if err := s.authorizeRPC("messages.after", json.RawMessage(`{"chat_id":8}`)); err == nil {
		t.Fatal("foreign chat was accepted")
	}
	if err := s.authorizeRPC("send", json.RawMessage(`{"chat_guid":"iMessage;+;other"}`)); err == nil {
		t.Fatal("foreign send target was accepted")
	}
	if err := s.authorizeRPC("send", json.RawMessage(`{"chat_guid":"iMessage;+;allowed","file":"/etc/passwd"}`)); err == nil {
		t.Fatal("arbitrary outbound file was accepted")
	}
	if err := s.authorizeRPC("chats.get", json.RawMessage(`{}`)); err == nil {
		t.Fatal("unexposed imsg method was accepted")
	}
}

func TestOutboundAttachmentIsOpaqueOneShotStaging(t *testing.T) {
	root := t.TempDir()
	s := &server{outboundRoot: root, maxAttachmentBytes: 1024, allowedChatGUID: "iMessage;+;allowed"}
	request := httptest.NewRequest(http.MethodPost, "/outbound-attachment?filename=photo.jpg&mime_type=image%2Fjpeg", bytes.NewReader([]byte("jpeg-bytes")))
	response := httptest.NewRecorder()
	s.outboundAttachment(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("upload failed: %d %s", response.Code, response.Body.String())
	}
	var uploaded struct {
		ID string `json:"upload_id"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &uploaded); err != nil {
		t.Fatal(err)
	}
	if len(uploaded.ID) != 64 {
		t.Fatalf("unexpected upload id: %q", uploaded.ID)
	}
	raw := json.RawMessage(`{"chat_guid":"iMessage;+;allowed","file":"upload:` + uploaded.ID + `"}`)
	if err := s.authorizeRPC("send", raw); err != nil {
		t.Fatalf("opaque upload rejected: %v", err)
	}
	prepared, cleanup, err := s.prepareRPC("send", raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(prepared), "upload:") || !strings.Contains(string(prepared), root) {
		t.Fatalf("upload was not resolved only inside the bridge: %s", prepared)
	}
	value, ok := s.outboundAttachments.Load(uploaded.ID)
	if !ok {
		t.Fatal("staged upload disappeared before send")
	}
	path := value.(attachmentRecord).path
	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("staged file survived one-shot cleanup: %v", err)
	}
	if _, ok := s.outboundAttachments.Load(uploaded.ID); ok {
		t.Fatal("one-shot upload handle survived cleanup")
	}
}

func TestCleanOrphanedOutboundAttachmentsIsNarrow(t *testing.T) {
	root := t.TempDir()
	orphan := strings.Repeat("a", 64) + "-photo.jpg"
	temporary := ".upload-123"
	unrelated := "operator-note.txt"
	for _, name := range []string{orphan, temporary, unrelated} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, strings.Repeat("b", 64)+"-directory"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := cleanOrphanedOutboundAttachments(root); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{orphan, temporary} {
		if _, err := os.Stat(filepath.Join(root, name)); !os.IsNotExist(err) {
			t.Fatalf("bridge orphan %q survived cleanup: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, unrelated)); err != nil {
		t.Fatalf("unrelated file was removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, strings.Repeat("b", 64)+"-directory")); err != nil {
		t.Fatalf("directory was removed: %v", err)
	}
}

func TestSanitizeMessagesReplacesHostPathWithOpaqueHandle(t *testing.T) {
	root := t.TempDir()
	attachmentPath := filepath.Join(root, "photo.jpg")
	if err := os.WriteFile(attachmentPath, []byte("jpeg-bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &server{attachmentRoot: root, maxAttachmentBytes: 1024}
	s.allowedChatIDs.Store("7", struct{}{})
	raw, err := json.Marshal(map[string]any{
		"messages": []any{map[string]any{
			"chat_id": 7,
			"attachments": []any{map[string]any{
				"path": attachmentPath, "mime_type": "image/jpeg", "transfer_name": "photo.jpg",
			}},
		}},
		"next_rowid": 9,
	})
	if err != nil {
		t.Fatal(err)
	}

	sanitized, err := s.sanitizeMessages(raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(sanitized), root) || strings.Contains(string(sanitized), `"path"`) {
		t.Fatalf("host path leaked: %s", sanitized)
	}
	var result struct {
		Messages []struct {
			Attachments []struct {
				ID string `json:"attachment_id"`
			} `json:"attachments"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(sanitized, &result); err != nil {
		t.Fatal(err)
	}
	id := result.Messages[0].Attachments[0].ID
	if len(id) != 64 {
		t.Fatalf("opaque id has unexpected shape: %q", id)
	}
	if _, ok := s.attachments.Load(id); !ok {
		t.Fatal("opaque attachment was not registered")
	}
}

func TestRegisterAttachmentRejectsOutsideRoot(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &server{attachmentRoot: root, maxAttachmentBytes: 1024}
	if _, _, err := s.registerAttachment(outside, map[string]any{}); err == nil {
		t.Fatal("outside path was accepted")
	}
}
