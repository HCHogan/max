package main

import (
	"bytes"
	"crypto/aes"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"testing"
)

// buildDat produces a container shaped exactly like the ones WeChat 4.x writes:
// header, the first aesSize plaintext bytes under AES-128-ECB with a PKCS7
// block, then the remainder under a single-byte XOR.
func buildDat(t *testing.T, plain []byte, key []byte, xorByte byte, aesSize int) []byte {
	t.Helper()
	if len(plain) < aesSize {
		t.Fatalf("plaintext shorter than the AES region")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	head := make([]byte, aesSize)
	copy(head, plain[:aesSize])
	padding := aes.BlockSize - aesSize%aes.BlockSize
	for i := 0; i < padding; i++ {
		head = append(head, byte(padding))
	}
	cipherText := make([]byte, len(head))
	for offset := 0; offset < len(head); offset += aes.BlockSize {
		block.Encrypt(cipherText[offset:offset+aes.BlockSize], head[offset:offset+aes.BlockSize])
	}
	tail := make([]byte, len(plain)-aesSize)
	for i, value := range plain[aesSize:] {
		tail[i] = value ^ xorByte
	}

	out := make([]byte, 0, datHeaderSize+len(cipherText)+len(tail))
	out = append(out, datSignature...)
	out = binary.LittleEndian.AppendUint32(out, uint32(aesSize))
	out = binary.LittleEndian.AppendUint32(out, uint32(len(tail)))
	out = append(out, 0x01)
	out = append(out, cipherText...)
	out = append(out, tail...)
	return out
}

func samplePlaintext(n int) []byte {
	plain := make([]byte, n)
	copy(plain, []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F'})
	for i := 10; i < n-2; i++ {
		plain[i] = byte(i * 7 % 251)
	}
	if n >= 2 {
		plain[n-2], plain[n-1] = 0xFF, 0xD9
	}
	return plain
}

func TestDatRoundTrip(t *testing.T) {
	key := []byte("0123456789abcdef")
	plain := samplePlaintext(4096)
	container := buildDat(t, plain, key, 0xC0, 1024)

	layout, err := parseDat(container)
	if err != nil {
		t.Fatalf("parseDat: %v", err)
	}
	// The observed invariant on every real file: the container carries exactly
	// 31 bytes more than the image, being the header plus one padding block.
	if got := len(container) - layout.plainBytes; got != 31 {
		t.Fatalf("container overhead = %d, want 31", got)
	}
	if layout.plainBytes != len(plain) {
		t.Fatalf("plainBytes = %d, want %d", layout.plainBytes, len(plain))
	}

	sum := md5.Sum(plain)
	want := map[string]bool{hex.EncodeToString(sum[:]): true}
	out, xorByte, digest, err := decryptDat(container, key, nil, digestAccept(want))
	if err != nil {
		t.Fatalf("decryptDat: %v", err)
	}
	if xorByte != 0xC0 {
		t.Fatalf("recovered XOR byte = %#x, want 0xC0", xorByte)
	}
	if !want[digest] || !bytes.Equal(out, plain) {
		t.Fatal("decrypted bytes differ from the original")
	}
}

// A wrong key must fail, not return plausible rubbish: /fetch-image treats a
// returned image as verified, so the digest is the whole guarantee.
func TestDatRejectsWrongKey(t *testing.T) {
	plain := samplePlaintext(2048)
	container := buildDat(t, plain, []byte("0123456789abcdef"), 0xC0, 1024)
	sum := md5.Sum(plain)
	want := map[string]bool{hex.EncodeToString(sum[:]): true}

	if _, _, _, err := decryptDat(container, []byte("fedcba9876543210"), nil, digestAccept(want)); err == nil {
		t.Fatal("a wrong key produced an accepted image")
	}
}

// A thumbnail carries no published digest, so the key hunt leans on JPEG
// structure instead. That check has to be strict at both ends: a wrong key
// scrambles the head, a wrong XOR byte scrambles the tail, and accepting
// either would hand /fetch-image an image it has not actually verified.
func TestJPEGAcceptRequiresBothEnds(t *testing.T) {
	good := samplePlaintext(600)
	if !jpegAccept(good) {
		t.Fatal("a well-formed JPEG was rejected")
	}
	headBroken := append([]byte(nil), good...)
	headBroken[1] = 0x00
	if jpegAccept(headBroken) {
		t.Error("accepted a JPEG with a broken start marker")
	}
	tailBroken := append([]byte(nil), good...)
	tailBroken[len(tailBroken)-1] = 0x00
	if jpegAccept(tailBroken) {
		t.Error("accepted a JPEG with a broken end marker")
	}
}

// The XOR byte is recoverable from a thumbnail alone, because thumbnails stay
// JPEG even when the full image is HEVC — which is what makes the byte
// knowable without going near the client's memory.
func TestDeriveXORKeyFromThumbnail(t *testing.T) {
	plain := samplePlaintext(3000)
	container := buildDat(t, plain, []byte("0123456789abcdef"), 0xC0, 1024)
	got, err := deriveXORKey(container)
	if err != nil {
		t.Fatalf("deriveXORKey: %v", err)
	}
	if got != 0xC0 {
		t.Fatalf("derived %#x, want 0xC0", got)
	}
}

func TestParseDatRejectsForeignFiles(t *testing.T) {
	if _, err := parseDat([]byte("not a wechat container at all")); err == nil {
		t.Fatal("accepted a file with no V2 signature")
	}
}

func TestLooksLikeImageHeader(t *testing.T) {
	cases := []struct {
		name  string
		input []byte
		want  bool
	}{
		{"jpeg", []byte{0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0}, true},
		{"heif", []byte{0, 0, 0, 0x20, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c'}, true},
		{"png", append([]byte{0x89}, []byte("PNG\r\n\x1a\n\x00\x00\x00\x00")...), true},
		{"random", []byte{0x3f, 0x91, 0x02, 0xaa, 0x51, 0x7c, 0xd0, 0x11, 0x9e, 0x4f, 0x22, 0x08}, false},
		{"short", []byte{0xFF, 0xD8}, false},
	}
	for _, tc := range cases {
		if got := looksLikeImageHeader(tc.input); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}
