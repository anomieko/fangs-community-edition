//go:build windows

package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	ole32    = syscall.NewLazyDLL("ole32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
)

// freeSpace: bytes this user may still write on the drive dir is on (dir need not exist yet).
func freeSpace(dir string) (int64, bool) {
	for !exists(dir) && filepath.Dir(dir) != dir {
		dir = filepath.Dir(dir)
	}
	p, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return 0, false
	}
	var free uint64
	r, _, _ := kernel32.NewProc("GetDiskFreeSpaceExW").Call(uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&free)), 0, 0)
	return int64(free), r != 0
}

const (
	folderDesktop  = 0x10 // CSIDL_DESKTOPDIRECTORY (follows OneDrive's redirect)
	folderPrograms = 0x02 // CSIDL_PROGRAMS: the Start menu
)

// shellFolder: the current user's desktop or Start menu folder ("" if Windows doesn't say).
func shellFolder(csidl int) string {
	buf := make([]uint16, syscall.MAX_PATH)
	r, _, _ := shell32.NewProc("SHGetFolderPathW").Call(0, uintptr(csidl), 0, 0, uintptr(unsafe.Pointer(&buf[0])))
	if r != 0 {
		return ""
	}
	return syscall.UTF16ToString(buf)
}

type guid struct {
	d1     uint32
	d2, d3 uint16
	d4     [8]byte
}

var (
	clsidShellLink = guid{0x00021401, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidShellLinkW  = guid{0x000214F9, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidPersistFile = guid{0x0000010B, 0, 0, [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
)

// comObject: what a COM interface pointer points to (its function table comes first).
type comObject struct{ vtbl *[32]uintptr }

func (o *comObject) this() uintptr { return uintptr(unsafe.Pointer(o)) }

func hresult(what string, r uintptr) error {
	if int32(r) < 0 {
		return fmt.Errorf("%s failed (0x%08x)", what, uint32(r))
	}
	return nil
}

// createShortcut writes a .lnk through Windows' own shell link object (IShellLinkW, IPersistFile).
func createShortcut(lnk, target, workDir, icon, description string) error {
	runtime.LockOSThread() // COM objects belong to the thread that made them
	defer runtime.UnlockOSThread()
	if r, _, _ := ole32.NewProc("CoInitializeEx").Call(0, 2); int32(r) >= 0 { // COINIT_APARTMENTTHREADED
		defer ole32.NewProc("CoUninitialize").Call()
	}
	var link *comObject
	r, _, _ := ole32.NewProc("CoCreateInstance").Call(uintptr(unsafe.Pointer(&clsidShellLink)), 0, 1, // CLSCTX_INPROC_SERVER
		uintptr(unsafe.Pointer(&iidShellLinkW)), uintptr(unsafe.Pointer(&link)))
	if err := hresult("CoCreateInstance", r); err != nil {
		return err
	}
	defer syscall.SyscallN(link.vtbl[2], link.this()) // Release

	// IShellLinkW: 20 SetPath, 9 SetWorkingDirectory, 7 SetDescription, 17 SetIconLocation
	for _, s := range []struct {
		i     int
		name  string
		value string
	}{{20, "SetPath", target}, {9, "SetWorkingDirectory", workDir}, {7, "SetDescription", description}, {17, "SetIconLocation", icon}} {
		p, err := syscall.UTF16PtrFromString(s.value)
		if err != nil {
			return err
		}
		r, _, _ := syscall.SyscallN(link.vtbl[s.i], link.this(), uintptr(unsafe.Pointer(p)), 0) // (SetIconLocation's index 0)
		if err := hresult(s.name, r); err != nil {
			return err
		}
	}
	var file *comObject
	r, _, _ = syscall.SyscallN(link.vtbl[0], link.this(), uintptr(unsafe.Pointer(&iidPersistFile)), uintptr(unsafe.Pointer(&file))) // QueryInterface
	if err := hresult("QueryInterface", r); err != nil {
		return err
	}
	defer syscall.SyscallN(file.vtbl[2], file.this()) // Release
	p, err := syscall.UTF16PtrFromString(lnk)
	if err != nil {
		return err
	}
	r, _, _ = syscall.SyscallN(file.vtbl[6], file.this(), uintptr(unsafe.Pointer(p)), 1) // IPersistFile.Save
	return hresult("Save", r)
}
