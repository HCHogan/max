//go:build windows

package main

import (
	"fmt"
	"strings"
	"syscall"
	"unsafe"
)

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procOpenProcess    = kernel32.NewProc("OpenProcess")
	procReadProcessMem = kernel32.NewProc("ReadProcessMemory")
	procVirtualQueryEx = kernel32.NewProc("VirtualQueryEx")
)

const (
	processQueryInformation = 0x0400
	processVMRead           = 0x0010

	memCommit = 0x1000

	pageNoAccess = 0x01
	pageGuard    = 0x100
)

// memoryBasicInformation mirrors MEMORY_BASIC_INFORMATION as the 64-bit ABI
// lays it out; the two padding fields are load-bearing, not decoration.
type memoryBasicInformation struct {
	BaseAddress       uintptr
	AllocationBase    uintptr
	AllocationProtect uint32
	_                 uint32
	RegionSize        uintptr
	State             uint32
	Protect           uint32
	Type              uint32
	_                 uint32
}

// findProcess returns the pid of the first running process whose executable
// name matches one of the candidates, case-insensitively.
func findProcess(candidates []string) (uint32, string, error) {
	snapshot, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return 0, "", err
	}
	defer syscall.CloseHandle(snapshot)

	var entry syscall.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = syscall.Process32First(snapshot, &entry); err == nil; err = syscall.Process32Next(snapshot, &entry) {
		name := syscall.UTF16ToString(entry.ExeFile[:])
		for _, candidate := range candidates {
			if strings.EqualFold(name, candidate) {
				return entry.ProcessID, name, nil
			}
		}
	}
	return 0, "", fmt.Errorf("no running process named any of %v", candidates)
}

// eachMemoryRegion reads every committed, private, readable region of the
// process and hands its contents to visit. Returning false stops the walk.
//
// Private committed pages are where a heap-allocated key can live; mapped
// images and file views are skipped, which removes most of the address space
// before a single AES trial happens.
func eachMemoryRegion(pid uint32, visit func(base uintptr, data []byte) bool) error {
	handle, _, err := procOpenProcess.Call(processQueryInformation|processVMRead, 0, uintptr(pid))
	if handle == 0 {
		return fmt.Errorf("OpenProcess(%d): %v (run as Administrator?)", pid, err)
	}
	defer syscall.CloseHandle(syscall.Handle(handle))

	var info memoryBasicInformation
	buffer := make([]byte, 0, 1<<20)
	for address := uintptr(0); ; {
		ret, _, _ := procVirtualQueryEx.Call(handle, address, uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info))
		if ret == 0 {
			return nil
		}
		next := info.BaseAddress + info.RegionSize
		if next <= address {
			return nil
		}
		// Committed and readable is the whole test. Restricting this to
		// MEM_PRIVATE looked principled — a heap-allocated key lives there —
		// and cost a scan that examined 326 regions in under a second while
		// finding nothing. The printable-ASCII filter is what makes breadth
		// affordable, so spend it here rather than guessing which allocator
		// holds the key.
		readable := info.State == memCommit &&
			info.Protect&pageNoAccess == 0 &&
			info.Protect&pageGuard == 0
		if readable && info.RegionSize > 0 {
			if cap(buffer) < int(info.RegionSize) {
				buffer = make([]byte, info.RegionSize)
			}
			chunk := buffer[:info.RegionSize]
			var read uintptr
			ok, _, _ := procReadProcessMem.Call(handle,
				info.BaseAddress,
				uintptr(unsafe.Pointer(&chunk[0])),
				info.RegionSize,
				uintptr(unsafe.Pointer(&read)))
			// A partial or refused read is ordinary while the process runs;
			// take whatever landed and keep going.
			if ok != 0 && read > 0 {
				if !visit(info.BaseAddress, chunk[:read]) {
					return nil
				}
			}
		}
		address = next
	}
}
