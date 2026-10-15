//go:build windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"unsafe"
)

// Run on Windows, or with Wine: GOOS=windows go test -c -o t.exe && wine t.exe -test.v
func TestCreateShortcut(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "Fangs Community Edition", "FangsCE.exe")
	mkfile(t, target, "x")
	lnk := filepath.Join(dir, "Fangs Community Edition.lnk")
	if err := createShortcut(lnk, target, filepath.Dir(target), target, "Updates the game and starts it"); err != nil {
		t.Fatal(err)
	}

	// read it back through the shell: IPersistFile.Load, IShellLinkW.GetPath
	var link, file *comObject
	ole32.NewProc("CoInitializeEx").Call(0, 2)
	r, _, _ := ole32.NewProc("CoCreateInstance").Call(uintptr(unsafe.Pointer(&clsidShellLink)), 0, 1,
		uintptr(unsafe.Pointer(&iidShellLinkW)), uintptr(unsafe.Pointer(&link)))
	if err := hresult("CoCreateInstance", r); err != nil {
		t.Fatal(err)
	}
	r, _, _ = syscall.SyscallN(link.vtbl[0], link.this(), uintptr(unsafe.Pointer(&iidPersistFile)), uintptr(unsafe.Pointer(&file)))
	if err := hresult("QueryInterface", r); err != nil {
		t.Fatal(err)
	}
	p, _ := syscall.UTF16PtrFromString(lnk)
	r, _, _ = syscall.SyscallN(file.vtbl[5], file.this(), uintptr(unsafe.Pointer(p)), 0)
	if err := hresult("Load", r); err != nil {
		t.Fatal(err)
	}
	buf := make([]uint16, syscall.MAX_PATH)
	r, _, _ = syscall.SyscallN(link.vtbl[3], link.this(), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 4) // SLGP_RAWPATH
	if err := hresult("GetPath", r); err != nil {
		t.Fatal(err)
	}
	if got := syscall.UTF16ToString(buf); got != target {
		t.Fatalf("shortcut points to %q, want %q", got, target)
	}
}

func TestShellFoldersAndSpace(t *testing.T) {
	for _, f := range []int{folderDesktop, folderPrograms} {
		if d := shellFolder(f); d == "" || !exists(d) {
			t.Errorf("shell folder %#x: %q", f, d)
		}
	}
	if free, ok := freeSpace(filepath.Join(os.TempDir(), "not", "made", "yet")); !ok || free <= 0 {
		t.Errorf("free space: %d %v", free, ok)
	}
}

func TestResolveDirWindows(t *testing.T) {
	home := `C:\Users\tester`
	t.Setenv("USERPROFILE", home)
	for in, want := range map[string]string{
		`D:\Games`:            `D:\Games`,
		`"D:\Games\"`:         `D:\Games`,
		`Games`:               home + `\Games`,
		`D:/Games/FANGS`:      `D:\Games\FANGS`,
		`\Games`:              filepath.VolumeName(mustAbs(t, `\`)) + `\Games`,
		`C:\Users\tester\..\`: `C:\Users`,
	} {
		if got := resolveDir(in); got != want {
			t.Errorf("resolveDir(%q) = %q, want %q", in, got, want)
		}
	}
}

func mustAbs(t *testing.T, p string) string {
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
