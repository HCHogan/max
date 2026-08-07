package main

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

// A decrypted full-size image is not a picture yet. WeChat 4.x wraps an HEVC
// still in a container of its own, "wxgf": a short header, then a standard
// Annex-B elementary stream — VPS, SPS, PPS, IDR, exactly what a decoder
// expects. Thumbnails skip all this and are plain JPEG.
//
// Converting here rather than in max is what keeps the format knowledge in one
// place. The alternative — shipping wxgf onward — would need a new conversion
// stage threaded through max's media pipeline, to save installing one binary
// on the host that already runs WeChat.
var wxgfMagic = []byte("wxgf")

func isWXGF(plain []byte) bool {
	return len(plain) > len(wxgfMagic) && bytes.Equal(plain[:len(wxgfMagic)], wxgfMagic)
}

func isJPEG(plain []byte) bool {
	return len(plain) > 3 && plain[0] == 0xFF && plain[1] == 0xD8 && plain[2] == 0xFF
}

// hevcStream locates the elementary stream inside a wxgf container. The header
// is a fixed size in every sample seen, but the first Annex-B start code is
// what actually marks the boundary, so that is what is looked for.
func hevcStream(plain []byte) ([]byte, error) {
	start := bytes.Index(plain, []byte{0x00, 0x00, 0x00, 0x01})
	if start < 0 {
		return nil, fmt.Errorf("no Annex-B start code in a %d-byte wxgf payload", len(plain))
	}
	return plain[start:], nil
}

// toJPEG turns whatever was decrypted into something every consumer can read.
// A thumbnail is already there and passes through untouched; a full image goes
// through ffmpeg once.
func toJPEG(ffmpegPath string, plain []byte) ([]byte, string, error) {
	if isJPEG(plain) {
		return plain, "image/jpeg", nil
	}
	if !isWXGF(plain) {
		return nil, "", fmt.Errorf("neither JPEG nor wxgf (first bytes %x)", plain[:min(8, len(plain))])
	}
	stream, err := hevcStream(plain)
	if err != nil {
		return nil, "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	// -f hevc because the stream carries no container to sniff, and one frame
	// because a still is all a wxgf holds.
	command := exec.CommandContext(ctx, ffmpegPath,
		"-v", "error",
		"-f", "hevc",
		"-i", "pipe:0",
		"-frames:v", "1",
		"-f", "mjpeg",
		"pipe:1")
	command.Stdin = bytes.NewReader(stream)
	var out, errOut bytes.Buffer
	command.Stdout = &out
	command.Stderr = &errOut
	if err := command.Run(); err != nil {
		return nil, "", fmt.Errorf("ffmpeg: %v: %s", err, truncate(errOut.String(), 200))
	}
	if out.Len() == 0 {
		return nil, "", fmt.Errorf("ffmpeg produced no output: %s", truncate(errOut.String(), 200))
	}
	return out.Bytes(), "image/jpeg", nil
}
