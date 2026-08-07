package main

import "testing"

func TestHEVCStreamStartsAtAnnexB(t *testing.T) {
	payload := append([]byte("wxgf"), 0x13, 0x00, 0x02, 0x05, 0, 0, 0, 0, 0, 0, 0, 0)
	payload = append(payload, 0x40, 0x01, 0xa2, 0x03)
	payload = append(payload, 0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01)
	stream, err := hevcStream(payload)
	if err != nil {
		t.Fatalf("hevcStream: %v", err)
	}
	if len(stream) != 8 || stream[0] != 0 || stream[3] != 1 || stream[4] != 0x40 {
		t.Fatalf("stream starts at the wrong place: % x", stream)
	}
}

func TestHEVCStreamRejectsPayloadWithoutStartCode(t *testing.T) {
	if _, err := hevcStream([]byte("wxgf no start code here at all")); err == nil {
		t.Fatal("accepted a payload with no Annex-B start code")
	}
}

// Identity is what stands between max and a picture from the wrong
// conversation, so each way of establishing it is pinned, and so is every way
// of failing to.
func TestIdentifies(t *testing.T) {
	wxgf := append([]byte("wxgf"), make([]byte, 96)...)
	jpeg := append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, make([]byte, 96)...)
	other := make([]byte, 100)

	digests := map[string]bool{"a1b2c3": true}
	wanted := fetchRequest{Length: 100, HDLength: 4096}

	cases := []struct {
		name   string
		plain  []byte
		digest string
		want   string
		ok     bool
	}{
		{"published digest wins outright", other, "a1b2c3", "digest", true},
		{"mid length with wxgf magic", wxgf, "zzz", "length+magic", true},
		{"hd length with jpeg magic", append(jpeg, make([]byte, 4096-100)...), "zzz", "length+magic", true},
		{"right length, wrong content", other, "zzz", "", false},
		{"right magic, wrong length", append(wxgf, 0x00), "zzz", "", false},
		{"nothing at all", []byte{}, "zzz", "", false},
	}
	for _, tc := range cases {
		how, ok := identifies(tc.plain, tc.digest, digests, wanted)
		if ok != tc.ok || how != tc.want {
			t.Errorf("%s: got (%q, %v), want (%q, %v)", tc.name, how, ok, tc.want, tc.ok)
		}
	}
}

// A thumbnail is already a picture; converting it would be a re-encode for
// nothing.
func TestToJPEGPassesThroughAThumbnail(t *testing.T) {
	jpeg := []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F'}
	out, contentType, err := toJPEG("/nonexistent-ffmpeg", jpeg)
	if err != nil {
		t.Fatalf("toJPEG: %v", err)
	}
	if contentType != "image/jpeg" || len(out) != len(jpeg) {
		t.Fatalf("got %s, %d bytes", contentType, len(out))
	}
}

func TestToJPEGRejectsUnknownContainers(t *testing.T) {
	if _, _, err := toJPEG("ffmpeg", []byte("PK\x03\x04 a zip file, somehow")); err == nil {
		t.Fatal("accepted a container that is neither JPEG nor wxgf")
	}
}
