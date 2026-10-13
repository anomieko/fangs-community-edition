//go:build windows

package main

import "syscall"

// enableTerminalColors turns on ANSI escape sequences in the Windows console (Windows 10+).
func enableTerminalColors() {
	k32 := syscall.NewLazyDLL("kernel32.dll")
	getMode, setMode := k32.NewProc("GetConsoleMode"), k32.NewProc("SetConsoleMode")
	h, err := syscall.GetStdHandle(syscall.STD_OUTPUT_HANDLE)
	if err != nil {
		return
	}
	var mode uint32
	if r, _, _ := getMode.Call(uintptr(h), uintptr(unsafePointer(&mode))); r == 0 {
		return
	}
	const enableVirtualTerminalProcessing = 0x0004
	setMode.Call(uintptr(h), uintptr(mode|enableVirtualTerminalProcessing))
}
