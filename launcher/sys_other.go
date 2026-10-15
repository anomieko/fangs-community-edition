//go:build !windows

package main

import (
	"errors"
	"path/filepath"
	"syscall"
)

// freeSpace: bytes this user may still write on the drive dir is on (dir need not exist yet).
func freeSpace(dir string) (int64, bool) {
	for !exists(dir) && filepath.Dir(dir) != dir {
		dir = filepath.Dir(dir)
	}
	var s syscall.Statfs_t
	if syscall.Statfs(dir, &s) != nil {
		return 0, false
	}
	return int64(s.Bavail) * int64(s.Bsize), true
}

const folderDesktop, folderPrograms = 0, 0

func shellFolder(int) string { return "" }

func createShortcut(lnk, target, workDir, icon, description string) error {
	return errors.New("shortcuts are made on Windows only")
}
