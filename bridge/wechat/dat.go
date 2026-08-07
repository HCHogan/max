package main

import (
	"bytes"
	"crypto/aes"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"log"
	"runtime"
	"sync"
	"sync/atomic"
)

// WeChat 4.x stores a received image as a "V2" container: a short header, then
// the first aes_size plaintext bytes under AES-128-ECB, then an untouched
// middle, then the last xor_size bytes under a single-byte XOR.
//
// Both keys are per-installation constants — proven here rather than assumed,
// since six different thumbnails from this account share a byte-identical
// first ciphertext block, which only happens when the same plaintext meets the
// same key. That is what makes a one-time key hunt worth doing: find them once
// and every later image decrypts locally, with no dependence on the hook's
// /Decode_Pic, which on 4.x reports success and writes nothing at all.
const (
	datHeaderSize = 15
	datAESOffset  = 6
	datXOROffset  = 10
)

var datSignature = []byte{0x07, 0x08, 'V', '2', 0x08, 0x07}

type datLayout struct {
	aesSize    int // plaintext bytes covered by AES
	xorSize    int // trailing plaintext bytes covered by the XOR byte
	cipherLen  int // encrypted length of the AES region
	rawOffset  int
	rawLen     int
	xorOffset  int
	plainBytes int
}

func parseDat(b []byte) (datLayout, error) {
	var layout datLayout
	if len(b) < datHeaderSize+aes.BlockSize {
		return layout, fmt.Errorf("too short (%d bytes)", len(b))
	}
	if !bytes.Equal(b[:len(datSignature)], datSignature) {
		return layout, fmt.Errorf("not a V2 container (magic %x)", b[:len(datSignature)])
	}
	aesSize := int(binary.LittleEndian.Uint32(b[datAESOffset:]))
	xorSize := int(binary.LittleEndian.Uint32(b[datXOROffset:]))
	if aesSize < 0 || xorSize < 0 {
		return layout, fmt.Errorf("implausible sizes aes=%d xor=%d", aesSize, xorSize)
	}
	// PKCS7 always appends between 1 and 16 bytes, so a region that is already
	// a multiple of the block size grows by a whole block.
	cipherLen := aesSize + aes.BlockSize - aesSize%aes.BlockSize
	xorOffset := len(b) - xorSize
	rawOffset := datHeaderSize + cipherLen
	rawLen := xorOffset - rawOffset
	if rawLen < 0 || xorOffset < rawOffset {
		return layout, fmt.Errorf("sizes do not fit the file (aes=%d xor=%d len=%d)", aesSize, xorSize, len(b))
	}
	layout = datLayout{
		aesSize:    aesSize,
		xorSize:    xorSize,
		cipherLen:  cipherLen,
		rawOffset:  rawOffset,
		rawLen:     rawLen,
		xorOffset:  xorOffset,
		plainBytes: aesSize + rawLen + xorSize,
	}
	return layout, nil
}

// firstCipherBlock is the one block a key candidate is tested against: it
// decrypts to the start of an image file, whose magic is known even when the
// rest of the plaintext is not.
func firstCipherBlock(b []byte) ([]byte, error) {
	layout, err := parseDat(b)
	if err != nil {
		return nil, err
	}
	if layout.cipherLen < aes.BlockSize {
		return nil, fmt.Errorf("no AES region")
	}
	return b[datHeaderSize : datHeaderSize+aes.BlockSize], nil
}

// decryptAESRegion recovers the plaintext head, dropping the padding block.
func decryptAESRegion(b []byte, layout datLayout, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	source := b[datHeaderSize : datHeaderSize+layout.cipherLen]
	head := make([]byte, len(source))
	for offset := 0; offset+aes.BlockSize <= len(source); offset += aes.BlockSize {
		block.Decrypt(head[offset:offset+aes.BlockSize], source[offset:offset+aes.BlockSize])
	}
	return head[:layout.aesSize], nil
}

func assemble(head []byte, b []byte, layout datLayout, xorByte byte) []byte {
	out := make([]byte, 0, layout.plainBytes)
	out = append(out, head...)
	out = append(out, b[layout.rawOffset:layout.rawOffset+layout.rawLen]...)
	for _, value := range b[layout.xorOffset:] {
		out = append(out, value^xorByte)
	}
	return out
}

// digestAccept builds the strongest available verifier: the digest WeChat
// published for the very image being recovered.
func digestAccept(want map[string]bool) func([]byte) bool {
	if len(want) == 0 {
		return nil
	}
	return func(plain []byte) bool {
		sum := md5.Sum(plain)
		return want[hex.EncodeToString(sum[:])]
	}
}

// jpegAccept verifies by structure instead, for the case where no digest is on
// hand: a thumbnail. WeChat publishes no MD5 for thumbnails, but it does keep
// them JPEG — the full image is HEVC, and may be in a WeChat-only wrapper whose
// magic nothing here would recognise, which is exactly why a thumbnail is the
// better sample to hunt a key with.
func jpegAccept(plain []byte) bool {
	return len(plain) > 4 &&
		plain[0] == 0xFF && plain[1] == 0xD8 && plain[2] == 0xFF &&
		plain[len(plain)-2] == 0xFF && plain[len(plain)-1] == 0xD9
}

// decryptDat recovers the original image. When xorByte is nil every value is
// tried and the first one accept approves wins, which is also how the XOR byte
// is discovered in the first place; pinning it in config turns 256 attempts
// back into one.
func decryptDat(b, key []byte, xorByte *byte, accept func([]byte) bool) ([]byte, byte, string, error) {
	layout, err := parseDat(b)
	if err != nil {
		return nil, 0, "", err
	}
	head, err := decryptAESRegion(b, layout, key)
	if err != nil {
		return nil, 0, "", err
	}
	// A pinned byte is the operator's answer, so it is applied and reported
	// whatever the digest says; judging the result is the caller's job, and it
	// needs the digest in hand to say anything useful about a mismatch.
	if xorByte != nil {
		out := assemble(head, b, layout, *xorByte)
		sum := md5.Sum(out)
		return out, *xorByte, hex.EncodeToString(sum[:]), nil
	}
	for value := 0; value < 256; value++ {
		out := assemble(head, b, layout, byte(value))
		if accept != nil && !accept(out) {
			continue
		}
		sum := md5.Sum(out)
		return out, byte(value), hex.EncodeToString(sum[:]), nil
	}
	return nil, 0, "", fmt.Errorf("no XOR byte produced an acceptable image")
}

// looksLikeImageHeader is the cheap first filter on a key candidate. A wrong
// key yields effectively random bytes, so the chance of a false accept is
// about one in sixteen million per trial — small enough to leave the expensive
// full-file verification for the handful that survive.
func looksLikeImageHeader(p []byte) bool {
	if len(p) < 12 {
		return false
	}
	switch {
	case p[0] == 0xFF && p[1] == 0xD8 && p[2] == 0xFF: // JPEG
		return true
	case string(p[4:8]) == "ftyp": // HEIF / HEIC / AVIF
		return true
	case p[0] == 0x89 && string(p[1:4]) == "PNG": // PNG
		return true
	case string(p[0:4]) == "GIF8": // GIF
		return true
	case string(p[0:4]) == "RIFF" && string(p[8:12]) == "WEBP": // WebP
		return true
	}
	return false
}

// deriveXORKey recovers the XOR byte from a thumbnail without touching the
// client at all. Thumbnails are JPEG whatever the full image turns out to be —
// WeChat 4.x encodes mid-size images as HEVC — and a JPEG ends with FF D9, so
// the last two stored bytes name the key twice over and confirm each other.
//
// On this account every thumbnail agreed on 0xC0.
func deriveXORKey(thumbnail []byte) (byte, error) {
	if len(thumbnail) < datHeaderSize+2 {
		return 0, fmt.Errorf("too short")
	}
	if !bytes.Equal(thumbnail[:len(datSignature)], datSignature) {
		return 0, fmt.Errorf("not a V2 container")
	}
	last := thumbnail[len(thumbnail)-2:]
	fromFF, fromD9 := last[0]^0xFF, last[1]^0xD9
	if fromFF != fromD9 {
		return 0, fmt.Errorf("tail %02x %02x is not an XOR-ed JPEG ending", last[0], last[1])
	}
	return fromFF, nil
}

// isASCIIKey reports whether a window could be the key at all. WeChat carries
// this key as printable ASCII, which collapses the search: a few bytes of
// comparison reject virtually every offset before any AES work happens, and
// what survives is small enough that scanning byte by byte costs nothing.
func isASCIIKey(window []byte) bool {
	for _, c := range window {
		if c < 0x20 || c > 0x7E {
			return false
		}
	}
	return true
}

// findImageKey hunts a running WeChat client's private memory for the AES key
// that opens sample, verifying every survivor against the digest WeChat itself
// published for that image. Two filters stand between a memory offset and an
// expensive check: the window must be printable ASCII, and the block it
// decrypts must carry an image's magic. Only then is the whole file assembled
// and hashed.
func findImageKey(sample []byte, accept func([]byte) bool, keySize int) ([]byte, byte, error) {
	block, err := firstCipherBlock(sample)
	if err != nil {
		return nil, 0, err
	}
	pid, name, err := findProcess([]string{"Weixin.exe", "WeChat.exe"})
	if err != nil {
		return nil, 0, err
	}
	log.Printf("find-key: scanning %s (pid %d) for a %d-byte printable key", name, pid, keySize)

	var (
		found    []byte
		foundXOR byte
		tried    atomic.Uint64
		regions  int
	)
	err = eachMemoryRegion(pid, func(base uintptr, data []byte) bool {
		regions++
		if len(data) < keySize {
			return true
		}
		workers := runtime.NumCPU()
		span := (len(data)-keySize)/workers + 1
		var mutex sync.Mutex
		var group sync.WaitGroup
		for worker := 0; worker < workers; worker++ {
			start := worker * span
			if start >= len(data)-keySize {
				break
			}
			end := min(start+span+keySize, len(data))
			group.Add(1)
			go func(chunk []byte) {
				defer group.Done()
				plain := make([]byte, aes.BlockSize)
				local := uint64(0)
				for offset := 0; offset+keySize <= len(chunk); offset++ {
					window := chunk[offset : offset+keySize]
					if !isASCIIKey(window) {
						continue
					}
					local++
					cipher, cerr := aes.NewCipher(window)
					if cerr != nil {
						continue
					}
					cipher.Decrypt(plain, block)
					if !looksLikeImageHeader(plain) {
						continue
					}
					key := append([]byte(nil), window...)
					out, xorByte, _, derr := decryptDat(sample, key, nil, accept)
					if derr != nil || out == nil {
						continue
					}
					mutex.Lock()
					if found == nil {
						found, foundXOR = key, xorByte
					}
					mutex.Unlock()
					return
				}
				tried.Add(local)
			}(data[start:end])
		}
		group.Wait()
		return found == nil
	})
	if err != nil {
		return nil, 0, err
	}
	if found != nil {
		log.Printf("find-key: matched after %d printable candidates across %d regions", tried.Load(), regions)
		return found, foundXOR, nil
	}
	return nil, 0, fmt.Errorf("no key found after %d printable candidates across %d regions; "+
		"is the client running, and has it displayed an image this session?", tried.Load(), regions)
}
