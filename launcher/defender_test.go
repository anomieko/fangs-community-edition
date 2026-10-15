package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// modServer serves a small game with the mod loader files; base is the launcher's download base.
func modServer(t *testing.T) (m *manifest, base string) {
	t.Helper()
	game := map[string]string{"MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe": "exe", "MOBA/Content/Data/version.txt": "b1"}
	for _, p := range modFiles {
		game[p] = "mod:" + p
	}
	m = &manifest{Build: "b1", Exe: "MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe"}
	for p, body := range game {
		sum := sha256.Sum256([]byte(body))
		m.Files = append(m.Files, manifestFile{Path: p, Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])})
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if body, ok := game[strings.TrimPrefix(r.URL.Path, "/files/")]; ok {
			w.Write([]byte(body))
		} else {
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(ts.Close)
	return m, ts.URL + "/"
}

func TestModLoaderRemoved(t *testing.T) {
	m, base := modServer(t)
	dir := t.TempDir()
	if err := syncFiles(base, dir, m); err != nil {
		t.Fatal(err)
	}
	if len(removedMods(dir, m)) != 0 || len(restoreMods(base, dir, m)) != 0 {
		t.Fatal("a complete install reported removed mod files")
	}

	// removed since the last start: named, and the update puts it back
	dwm := filepath.Join(dir, filepath.FromSlash(modFiles[0]))
	os.Remove(dwm)
	if got := removedMods(dir, m); len(got) != 1 || got[0] != modFiles[0] {
		t.Fatalf("removed since last start: %v", got)
	}
	if err := syncFiles(base, dir, m); err != nil || !exists(dwm) {
		t.Fatalf("not put back: %v", err)
	}

	// removed right after the download: fetched again and named
	ue4ss := filepath.Join(dir, filepath.FromSlash(modFiles[1]))
	os.Remove(ue4ss)
	if got := restoreMods(base, dir, m); len(got) != 1 || got[0] != modFiles[1] || !exists(ue4ss) {
		t.Fatalf("removed after the download: %v, back: %v", got, exists(ue4ss))
	}

	// a fresh install misses them all, but nothing was removed
	if len(removedMods(t.TempDir(), m)) != 0 {
		t.Fatal("a fresh install reported removed mod files")
	}
}

// A "game" that deletes the mod loader as it starts (what an antivirus does when the game loads it): the launcher
// says so and waits for Enter instead of closing.
func TestModLoaderRemovedAtLaunch(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake game is a shell script")
	}
	m, base := modServer(t)
	dir := t.TempDir()
	if err := syncFiles(base, dir, m); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, filepath.FromSlash(m.Exe))
	os.WriteFile(exe, []byte("#!/bin/sh\nrm -f dwmapi.dll\n"), 0o755)
	os.Chmod(exe, 0o755)
	defer func(w time.Duration) { launchWait = w }(launchWait)
	launchWait = time.Second
	stdin = bufio.NewReader(strings.NewReader("\n"))
	defer func() { stdin = bufio.NewReader(os.Stdin) }()

	if err := launch(settings{InstallDir: dir, Name: "tester", Secret: "s"}, m); err != nil {
		t.Fatal(err)
	}
	if _, err := stdin.ReadByte(); err != io.EOF {
		t.Fatal("the launcher closed without waiting for the player to read the warning")
	}
}
