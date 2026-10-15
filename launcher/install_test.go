package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func mkfile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestResolveDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	abs := filepath.Join(home, "Games")
	for in, want := range map[string]string{
		abs:              abs,
		`"` + abs + `"`:  abs, // Explorer's "Copy as path"
		"  " + abs + " ": abs,
		"Games":          abs, // from the user's folder, not from wherever the launcher runs
		filepath.Join("Games", "..", "Games", "FANGS"): filepath.Join(abs, "FANGS"),
	} {
		if got := resolveDir(in); got != want {
			t.Errorf("resolveDir(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGameDirIn(t *testing.T) {
	root := t.TempDir()
	downloads := filepath.Join(root, "Downloads")
	mkfile(t, filepath.Join(downloads, "FangsCE.exe"), "x")
	empty := filepath.Join(root, "Empty")
	os.MkdirAll(empty, 0o755)
	steam := filepath.Join(root, "FANGS")
	os.MkdirAll(filepath.Join(steam, "MOBA"), 0o755)
	mkfile(t, filepath.Join(steam, "FANGS.exe"), "x")
	ours := filepath.Join(root, "Mine")
	mkfile(t, statePath(ours), "{}")
	mkfile(t, filepath.Join(ours, "Engine", "x"), "x")
	for dir, want := range map[string]string{
		downloads:                  filepath.Join(downloads, installFolderName),
		empty:                      empty,
		filepath.Join(root, "New"): filepath.Join(root, "New"),
		steam:                      steam,
		ours:                       ours,
	} {
		if got := gameDirIn(dir); got != want {
			t.Errorf("gameDirIn(%q) = %q, want %q", dir, got, want)
		}
	}
}

func TestLooksLikeInvite(t *testing.T) {
	inv := makeInvite("203.0.113.10:8080", "code")
	for _, s := range []string{inv, strings.ToLower(inv), `"` + inv + `"`, "FCE-garbled", "http://203.0.113.10:8080/download/code/FangsCE.exe"} {
		if !looksLikeInvite(s) {
			t.Errorf("%q not taken for an invite", s)
		}
	}
	for _, s := range []string{`C:\Games`, "/home/x/Games", "Games", "fce_fan", "D:"} {
		if looksLikeInvite(s) {
			t.Errorf("%q taken for an invite", s)
		}
	}
}

func TestSettleInstallDir(t *testing.T) {
	home, cwd, exeDir := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))
	t.Chdir(cwd)
	inv := makeInvite("203.0.113.10:8080", "code")

	// an invite pasted as the folder, nothing installed yet: the default folder
	if got := settleInstallDir(inv, exeDir); got != defaultInstallDir() {
		t.Errorf("invite, nothing installed: %q", got)
	}
	// the game went next to the launcher under the invite's name: found and renamed
	mkfile(t, statePath(filepath.Join(exeDir, inv)), "{}")
	if got, want := settleInstallDir(inv, exeDir), filepath.Join(exeDir, installFolderName); got != want || !hasInstall(want) {
		t.Errorf("invite next to the launcher: %q, want %q", got, want)
	}
	// a relative folder with the game in the folder the launcher ran in: kept, made absolute
	mkfile(t, statePath(filepath.Join(cwd, "Games")), "{}")
	if got, want := settleInstallDir("Games", exeDir), filepath.Join(cwd, "Games"); got != want {
		t.Errorf("relative with the game: %q, want %q", got, want)
	}
	// a relative folder with nothing installed: from the user's folder
	if got, want := settleInstallDir("Other", exeDir), filepath.Join(home, "Other"); got != want {
		t.Errorf("relative, nothing installed: %q, want %q", got, want)
	}
	// a full folder with nothing installed: a subfolder; with the game in it: left alone
	full := filepath.Join(home, "Downloads")
	mkfile(t, filepath.Join(full, "holiday.jpg"), "x")
	if got, want := settleInstallDir(full, exeDir), filepath.Join(full, installFolderName); got != want {
		t.Errorf("full folder: %q, want %q", got, want)
	}
	mkfile(t, statePath(full), "{}")
	if got := settleInstallDir(full, exeDir); got != full {
		t.Errorf("installed in a full folder: %q", got)
	}
}

func TestCheckInstallDir(t *testing.T) {
	root := t.TempDir()
	if p := checkInstallDir(filepath.Join(root, "a", "b"), 1); p != "" {
		t.Errorf("good folder refused: %s", p)
	}
	if p := checkInstallDir(filepath.Join(root, "big"), 1<<60); !strings.Contains(p, "space") || exists(filepath.Join(root, "big")) {
		t.Errorf("no space: %q (and the folder made for the check must go)", p)
	}
	t.Setenv("OneDrive", filepath.Join(root, "OneDrive"))
	if p := checkInstallDir(filepath.Join(root, "OneDrive", "Desktop", "FANGS"), 1); !strings.Contains(p, "OneDrive") {
		t.Errorf("OneDrive folder accepted: %q", p)
	}
	if runtime.GOOS != "windows" && os.Getuid() != 0 {
		locked := filepath.Join(root, "locked")
		os.MkdirAll(locked, 0o555)
		if p := checkInstallDir(locked, 1); !strings.Contains(p, "Can't write") {
			t.Errorf("read-only folder accepted: %q", p)
		}
	}
	if p := checkInstallDir(filepath.Join(root, "a", "b"), 1); p != "" {
		t.Errorf("good folder refused after the OneDrive check: %s", p)
	}
}

// A first start against a test server: the invite pasted as the folder and as the name is caught, the game goes into
// a subfolder of the folder full of other things, and gets installed.
func TestFirstRun(t *testing.T) {
	game := map[string]string{"MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe": "exe", "MOBA/Content/Data/version.txt": "b1", "FangsCE/Engine.ini": "[x]"}
	m := manifest{Build: "b1", Exe: "MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe", EngineIni: "FangsCE/Engine.ini"}
	for p, body := range game {
		sum := sha256.Sum256([]byte(body))
		m.Files = append(m.Files, manifestFile{Path: p, Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])})
	}
	mj, _ := json.Marshal(m)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/download/code/manifest.json" {
			w.Write(mj)
		} else if body, ok := game[strings.TrimPrefix(r.URL.Path, "/download/code/files/")]; ok {
			w.Write([]byte(body))
		} else {
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()
	defer func(s, c string) { server, joinCode = s, c }(server, joinCode)
	server, joinCode = strings.TrimPrefix(ts.URL, "http://"), "code"

	home := t.TempDir()
	for _, v := range []string{"HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA", "LOCALAPPDATA"} {
		t.Setenv(v, home)
	}
	t.Setenv("FANGSCE_NO_LAUNCH", "1")
	downloads := filepath.Join(home, "Downloads")
	mkfile(t, filepath.Join(downloads, "FangsCE.exe"), "x")
	inv := makeInvite(server, "code")
	stdin = bufio.NewReader(strings.NewReader(inv + "\n" + downloads + "\n" + inv + "\n" + "tester\n"))
	defer func() { stdin = bufio.NewReader(os.Stdin) }()
	desktop, startMenu := filepath.Join(home, "Desktop"), filepath.Join(home, "Start Menu")
	os.MkdirAll(desktop, 0o755)
	os.MkdirAll(startMenu, 0o755)
	defer func(f func() []string) { shortcutFolders = f }(shortcutFolders)
	shortcutFolders = func() []string { return []string{desktop, startMenu} }

	if err := run(); err != nil {
		t.Fatal(err)
	}
	st, err := loadSettings(settingsPath())
	want := filepath.Join(downloads, installFolderName)
	if err != nil || st.InstallDir != want || st.Name != "tester" {
		t.Fatalf("settings %+v %v, want the game in %s", st, err, want)
	}
	if b, _ := os.ReadFile(filepath.Join(want, "MOBA", "Content", "Data", "version.txt")); string(b) != "b1" {
		t.Fatal("game not installed")
	}
	if runtime.GOOS == "windows" { // the launcher copied where the shortcuts point, and the shortcuts
		self, _ := os.Executable()
		if a, b := hashOrEmpty(self), hashOrEmpty(installedLauncher()); a == "" || a != b {
			t.Errorf("installed launcher missing or different (%s)", installedLauncher())
		}
		for _, d := range []string{desktop, startMenu} {
			if !exists(filepath.Join(d, installFolderName+".lnk")) {
				t.Errorf("no shortcut in %s", d)
			}
		}
		if !st.Shortcuts {
			t.Error("shortcuts not remembered")
		}
	}
}

func hashOrEmpty(p string) string { s, _ := hashFile(p); return s }
