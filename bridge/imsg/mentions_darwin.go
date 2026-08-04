//go:build darwin && cgo

package main

/*
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>
char *max_decode_imessage_mentions(const unsigned char *bytes, size_t length);
*/
import "C"

import (
	"encoding/json"
	"unsafe"
)

func decodeMentionSpans(body []byte) []mentionSpan {
	if len(body) == 0 {
		return nil
	}
	raw := C.max_decode_imessage_mentions((*C.uchar)(unsafe.Pointer(&body[0])), C.size_t(len(body)))
	if raw == nil {
		return nil
	}
	defer C.free(unsafe.Pointer(raw))
	var decoded []mentionSpan
	if json.Unmarshal([]byte(C.GoString(raw)), &decoded) != nil {
		return nil
	}
	spans := make([]mentionSpan, 0, len(decoded))
	for _, span := range decoded {
		if isIMessageHandle(span.Handle) && span.UTF16Location >= 0 && span.UTF16Length > 0 && span.Display != "" {
			spans = append(spans, span)
		}
	}
	return spans
}
