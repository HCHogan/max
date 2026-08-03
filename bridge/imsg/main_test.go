package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const confirmedMentionBodyHex = "040B73747265616D747970656481E803840140848484124E5341747472696275746564537472696E67008484084E534F626A656374008592848484084E53537472696E67019484012B0B4D617877656C6C2068657986840269490107928484840C4E5344696374696F6E61727900948401690392849696265F5F6B494D4261736557726974696E67446972656374696F6E4174747269627574654E616D658692848484084E534E756D626572008484074E5356616C7565009484012A848401719DFF86928496961D5F5F6B494D4D657373616765506172744174747269627574654E616D658692849B9C9D9D0086928496961C5F5F6B494D4D656E74696F6E436F6E6669726D65644D656E74696F6E869284969611686E6B68676E4069636C6F75642E636F6D868697020492849899029299929A929E929F8686"

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

func TestConfirmedMentionHandlesUsesIdentityNotDisplayText(t *testing.T) {
	// Real macOS typedstream shape for the rendered text "Maxwell hey".
	body, err := hex.DecodeString(confirmedMentionBodyHex)
	if err != nil {
		t.Fatal(err)
	}
	handles := confirmedMentionHandles(body)
	if len(handles) != 1 || handles[0] != "hnkhgn@icloud.com" {
		t.Fatalf("unexpected confirmed mentions: %#v", handles)
	}
	if got := confirmedMentionHandles([]byte("Maxwell hey hnkhgn@icloud.com")); len(got) != 0 {
		t.Fatalf("plain text was promoted to a mention: %#v", got)
	}
}

func TestSanitizeMessagesAddsOnlyConfirmedMentionHandles(t *testing.T) {
	root := t.TempDir()
	sqlite := filepath.Join(root, "sqlite3")
	script := "#!/bin/sh\nprintf '%s\\n' '[{\"row_id\":1123,\"attributed_body_hex\":\"" + confirmedMentionBodyHex + "\"}]'\n"
	if err := os.WriteFile(sqlite, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	s := &server{dbPath: filepath.Join(root, "chat.db"), sqlitePath: sqlite}
	s.allowedChatIDs.Store("7", struct{}{})
	raw := json.RawMessage(`{"messages":[{"id":1123,"chat_id":7,"text":"Maxwell hey"},{"id":1124,"chat_id":7,"text":"Maxwell plain"}]}`)
	sanitized, err := s.sanitizeMessages(raw)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Messages []struct {
			MentionedHandles []string `json:"mentioned_handles"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(sanitized, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Messages) != 2 || len(result.Messages[0].MentionedHandles) != 1 || result.Messages[0].MentionedHandles[0] != "hnkhgn@icloud.com" {
		t.Fatalf("confirmed mention was not enriched: %s", sanitized)
	}
	if len(result.Messages[1].MentionedHandles) != 0 {
		t.Fatalf("plain display text became a mention: %s", sanitized)
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
