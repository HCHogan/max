//go:build !windows

package main

import "errors"

// The key lives in a running WeChat client's memory, and that client only runs
// on the host this bridge is meant to run on. Everywhere else the scan is not
// merely unimplemented, it is meaningless — so it says so instead of silently
// finding nothing. Building for other platforms stays possible on purpose:
// `go vet` and the compile check are worth keeping cross-platform.

func findProcess([]string) (uint32, string, error) {
	return 0, "", errors.New("process lookup is only implemented on Windows")
}

func eachMemoryRegion(uint32, func(uintptr, []byte) bool) error {
	return errors.New("memory scanning is only implemented on Windows")
}
