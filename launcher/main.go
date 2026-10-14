// FangsCE.exe - the Fangs: Community Edition launcher.
//
// Installs the game from the community server, keeps it up to date (only files that changed are
// downloaded, downloads resume and every file is checked against its SHA-256), then starts it logged in
// to the server. The server address and the community join code are baked in at build time:
//
//	go build -ldflags "-X main.server=<host:port> -X main.joinCode=<code>" -o FangsCE.exe
//
// or, in the public build (GitHub Releases, nothing baked in), come from an invite code the player pastes on
// the first start (server/invite.sh makes it); both are kept in the settings.
//
// Server side: <server>/download/<join code>/manifest.json lists the files (player/build-manifest.py),
// <server>/download/<join code>/files/<path> serves them, <server>/download/<join code>/FangsCE.exe is the
// current launcher (it replaces itself when that changes).
//
// With main.pubKey set (server/deploy.sh does), the file list must carry a valid Ed25519 signature
// (manifest.json.sig) from the server owner's key, which never leaves their machine: neither a taken-over
// server nor someone on the network path can make the launcher install anything.
package main

import (
	"bufio"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

var (
	server   = "127.0.0.1:8080" // set with -ldflags -X
	joinCode = ""
	version  = "dev"
	pubKey   = "" // base64 Ed25519 public key; when set, unsigned file lists are refused
)

const (
	reset  = "\033[0m"
	bold   = "\033[1m"
	dim    = "\033[2m"
	red    = "\033[91m"
	green  = "\033[92m"
	yellow = "\033[93m"
	teal   = "\033[96m"
	purple = "\033[95m"
)

type manifestFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type manifest struct {
	Build     string         `json:"build"`
	Exe       string         `json:"exe"`
	EngineIni string         `json:"engine_ini"`
	Launcher  *manifestFile  `json:"launcher"`
	Files     []manifestFile `json:"files"`
}

type installedFile struct {
	Size    int64  `json:"size"`
	SHA256  string `json:"sha256"`
	ModTime int64  `json:"mtime"`
}

type settings struct {
	InstallDir string `json:"install_dir"`
	Name       string `json:"name"`
	Secret     string `json:"secret"`
	Server     string `json:"server,omitempty"`
	JoinCode   string `json:"join_code,omitempty"`
}

var stdin = bufio.NewReader(os.Stdin)

func main() {
	enableTerminalColors()
	fmt.Print("\033]0;Fangs: Community Edition\007")
	banner()
	if err := run(); err != nil {
		fmt.Printf("\n  %s%s%s\n", red, err, reset)
		pause()
		os.Exit(1)
	}
}

func run() error {
	self, _ := os.Executable()
	_ = os.Remove(self + ".old") // left behind by a self-update

	cfgPath := settingsPath()
	st, err := loadSettings(cfgPath)
	if err != nil {
		st, err = firstRun(cfgPath)
		if err != nil {
			return err
		}
	} else {
		fmt.Printf("  Welcome back, %s%s%s!\n\n", bold, st.Name, reset)
	}
	if err := useInvite(cfgPath, &st); err != nil {
		return err
	}
	base := downloadBase()

	fmt.Printf("  %sChecking for updates...%s\n", dim, reset)
	m, err := fetchManifest(base + "manifest.json")
	if err != nil {
		if gameInstalled(st) {
			fmt.Printf("  %sCan't reach the server (%v) - starting the version you have.%s\n", yellow, err, reset)
			return launch(st, nil)
		}
		return fmt.Errorf("can't reach the server to download the game: %v", err)
	}
	if m.Launcher != nil && selfUpdate(base, self, m.Launcher) {
		return nil // the new launcher has taken over
	}
	if err := switchBuild(st.InstallDir, m.Build); err != nil {
		return err
	}
	if err := syncFiles(base, st.InstallDir, m); err != nil {
		return err
	}
	return launch(st, m)
}

// ---------------------------------------------------------------- UI

func banner() {
	fmt.Println()
	fmt.Println(teal + bold + `   ███████  █████  ███    ██  ██████  ███████` + reset)
	fmt.Println(teal + bold + `   ██      ██   ██ ████   ██ ██       ██` + reset)
	fmt.Println(teal + bold + `   █████   ███████ ██ ██  ██ ██   ███ ███████` + reset)
	fmt.Println(teal + bold + `   ██      ██   ██ ██  ██ ██ ██    ██      ██` + reset)
	fmt.Println(teal + bold + `   ██      ██   ██ ██   ████  ██████  ███████` + reset)
	fmt.Println(purple + bold + `            C O M M U N I T Y   E D I T I O N` + reset)
	fmt.Printf("%s   unofficial fan project - free, non-commercial - launcher %s%s\n\n", dim, version, reset)
}

func pause() {
	fmt.Printf("\n  %sPress Enter to close.%s", dim, reset)
	_, _ = stdin.ReadString('\n')
}

func ask(prompt, def string) string {
	if def != "" {
		fmt.Printf("  %s %s[%s]%s: ", prompt, dim, def, reset)
	} else {
		fmt.Printf("  %s: ", prompt)
	}
	line, _ := stdin.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

var nameRx = regexp.MustCompile(`^[A-Za-z0-9_]{3,16}$`)

func firstRun(cfgPath string) (settings, error) {
	fmt.Printf("  %sWelcome to Fangs: Community Edition!%s\n\n", bold, reset)
	fmt.Println("  FANGS is back - kept alive by the people who made and loved it.")
	fmt.Println("  This launcher installs the game, keeps it updated and starts it for you.")
	fmt.Printf("  %sNot affiliated with or endorsed by the owners of FANGS. Free, no purchases, no data sold.%s\n\n", dim, reset)

	dir := ask("Where should the game go?", defaultInstallDir())
	dir = filepath.Clean(dir)
	var name string
	for {
		name = ask("Pick your player name (3-16 letters, numbers or _)", "")
		if nameRx.MatchString(name) {
			break
		}
		fmt.Printf("  %sThat name doesn't work - 3 to 16 characters, letters, numbers and _ only.%s\n", yellow, reset)
	}
	secret := make([]byte, 16)
	if _, err := rand.Read(secret); err != nil {
		return settings{}, err
	}
	st := settings{InstallDir: dir, Name: name, Secret: hex.EncodeToString(secret)}
	if err := saveSettings(cfgPath, st); err != nil {
		return settings{}, err
	}
	fmt.Printf("\n  Nice to meet you, %s%s%s! Your name is tied to this PC (%s).\n\n", bold, name, reset, cfgPath)
	return st, nil
}

// ---------------------------------------------------------------- invite

// An invite code says where the server is and carries the community join code:
// "FCE-" + base32("<host:port>/<join code>"). A pasted download link (http://<host:port>/download/<code>/...)
// works too. The signed file list still decides what gets installed, so a wrong invite can't install anything.
var (
	hostRx = regexp.MustCompile(`^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$`)
	codeRx = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	b32    = base32.StdEncoding.WithPadding(base32.NoPadding)
)

func parseInvite(s string) (srv, code string, ok bool) {
	s = strings.TrimSpace(s)
	if u, err := url.Parse(s); err == nil && u.Host != "" {
		if parts := strings.Split(strings.Trim(u.Path, "/"), "/"); len(parts) >= 2 && parts[0] == "download" {
			srv, code = u.Host, parts[1]
		}
	} else if rest, found := strings.CutPrefix(strings.ToUpper(s), "FCE-"); found {
		if b, err := b32.DecodeString(strings.NewReplacer("-", "", " ", "").Replace(rest)); err == nil {
			srv, code, _ = strings.Cut(string(b), "/")
		}
	}
	return srv, code, hostRx.MatchString(srv) && codeRx.MatchString(code)
}

func makeInvite(srv, code string) string { return "FCE-" + b32.EncodeToString([]byte(srv+"/"+code)) }

func downloadBase() string {
	return fmt.Sprintf("http://%s/download/%s/", server, url.PathEscape(joinCode))
}

// useInvite: a launcher with the server baked in remembers it (so the public build works later without an
// invite); the public build uses the remembered one or asks for an invite code until the server accepts it.
func useInvite(cfgPath string, st *settings) error {
	if joinCode != "" {
		if st.Server != server || st.JoinCode != joinCode {
			st.Server, st.JoinCode = server, joinCode
			_ = saveSettings(cfgPath, *st)
		}
		return nil
	}
	if st.JoinCode != "" {
		server, joinCode = st.Server, st.JoinCode
		return nil
	}
	fmt.Println("  You need an invite code to play - ask whoever invited you (it starts with FCE-).")
	for {
		srv, code, ok := parseInvite(ask("Paste your invite code", ""))
		if !ok {
			fmt.Printf("  %sThat isn't an invite code - copy the whole thing (FCE-...).%s\n", yellow, reset)
			continue
		}
		server, joinCode = srv, code
		if _, err := fetchSmall(downloadBase() + "manifest.json"); err != nil {
			if strings.HasPrefix(err.Error(), "server answered") {
				fmt.Printf("  %sThe server doesn't accept that invite code (%v) - check it or ask for a new one.%s\n", yellow, err, reset)
			} else {
				fmt.Printf("  %sCan't reach the server for that invite (%v) - try again in a moment.%s\n", yellow, err, reset)
			}
			continue
		}
		st.Server, st.JoinCode = srv, code
		fmt.Printf("  %sInvite accepted.%s\n\n", green, reset)
		return saveSettings(cfgPath, *st)
	}
}

// ---------------------------------------------------------------- settings

func settingsPath() string {
	dir, err := os.UserConfigDir() // %APPDATA% on Windows
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "FangsCE", "launcher.json")
}

func defaultInstallDir() string {
	if runtime.GOOS == "windows" {
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			return filepath.Join(d, "Fangs Community Edition")
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Fangs Community Edition")
}

func loadSettings(path string) (settings, error) {
	var st settings
	b, err := os.ReadFile(path)
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(b, &st); err != nil {
		return st, err
	}
	if st.InstallDir == "" || !nameRx.MatchString(st.Name) || st.Secret == "" {
		return st, errors.New("incomplete settings")
	}
	return st, nil
}

func saveSettings(path string, st settings) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(st, "", "  ")
	return writeFileAtomic(path, b)
}

func writeFileAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---------------------------------------------------------------- manifest / sync

var shortClient = &http.Client{Timeout: 20 * time.Second}
var longClient = &http.Client{} // big downloads: no overall timeout

func fetchSmall(u string) ([]byte, error) {
	resp, err := shortClient.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("server answered %s", resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 64<<20))
}

func fetchManifest(u string) (*manifest, error) {
	data, err := fetchSmall(u)
	if err != nil {
		return nil, err
	}
	if pubKey != "" {
		if err := verifySignature(data, u+".sig"); err != nil {
			return nil, err
		}
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("bad file list: %v", err)
	}
	if m.Exe == "" || len(m.Files) == 0 {
		return nil, errors.New("empty file list")
	}
	for _, f := range append([]manifestFile{{Path: m.Exe}}, m.Files...) {
		if !safeRel(f.Path) {
			return nil, fmt.Errorf("refusing unsafe path in file list: %q", f.Path)
		}
	}
	return &m, nil
}

// verifySignature: the file list must be signed with the server owner's key (see the top of this file).
func verifySignature(data []byte, sigURL string) error {
	pub, err := base64.StdEncoding.DecodeString(pubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return errors.New("this launcher has a broken signing key built in")
	}
	sigText, err := fetchSmall(sigURL)
	if err != nil {
		return fmt.Errorf("the update has no signature (%v) - not installing anything", err)
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sigText)))
	if err != nil || !ed25519.Verify(pub, data, sig) {
		return errors.New("the update is NOT signed by the server owner - not installing anything. Tell them!")
	}
	return nil
}

// safeRel: relative, forward slashes, no "..", no drive letters.
func safeRel(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") || strings.Contains(p, ":") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------- builds side by side

// The install folder holds the build the server runs; other builds wait next to it as "<install> [<build>]",
// so when the server switches builds back and forth the launcher moves folders instead of downloading again.
var buildRx = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

func installedBuild(installDir string) string {
	b, err := os.ReadFile(filepath.Join(installDir, "MOBA", "Content", "Data", "version.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func parkedDir(installDir, build string) string {
	return strings.TrimRight(installDir, `\/`) + " [" + build + "]"
}

func switchBuild(installDir, want string) error {
	have := installedBuild(installDir)
	if have == "" || have == want || !buildRx.MatchString(have) || !buildRx.MatchString(want) {
		return nil // nothing installed yet, same build, or names we don't trust as folder names: just sync
	}
	if _, err := os.Stat(parkedDir(installDir, have)); err == nil {
		return fmt.Errorf("can't set build %s aside: %s already exists - move it away and start again", have, parkedDir(installDir, have))
	}
	if err := os.Rename(installDir, parkedDir(installDir, have)); err != nil {
		return fmt.Errorf("can't set build %s aside (is the game still running?): %v", have, err)
	}
	if _, err := os.Stat(parkedDir(installDir, want)); err == nil {
		if err := os.Rename(parkedDir(installDir, want), installDir); err != nil {
			_ = os.Rename(parkedDir(installDir, have), installDir)
			return fmt.Errorf("can't switch to build %s: %v", want, err)
		}
		fmt.Printf("  The server runs %s%s%s again: switched back to it (%s is kept next to it).\n\n", bold, want, reset, have)
		return nil
	}
	fmt.Printf("  The server now runs %s%s%s. Your %s stays next to it, so switching back later is instant.\n\n", bold, want, reset, have)
	return os.MkdirAll(installDir, 0o755)
}

func statePath(installDir string) string {
	return filepath.Join(installDir, ".fangsce", "installed.json")
}

func loadState(installDir string) map[string]installedFile {
	st := map[string]installedFile{}
	if b, err := os.ReadFile(statePath(installDir)); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}

func saveState(installDir string, st map[string]installedFile) {
	p := statePath(installDir)
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	b, _ := json.Marshal(st)
	_ = writeFileAtomic(p, b)
}

func syncFiles(base, installDir string, m *manifest) error {
	state := loadState(installDir)
	var todo []manifestFile
	var total int64
	wanted := map[string]bool{}
	checking := 0
	for _, f := range m.Files {
		wanted[f.Path] = true
		dst := filepath.Join(installDir, filepath.FromSlash(f.Path))
		info, err := os.Stat(dst)
		if err == nil && info.Size() == f.Size {
			if s, ok := state[f.Path]; ok && s.SHA256 == f.SHA256 && s.Size == f.Size && s.ModTime == info.ModTime().UnixNano() {
				continue // unchanged since we installed it
			}
			checking++
			fmt.Printf("\r  %sVerifying installed files... %d%s", dim, checking, reset)
			if sum, err := hashFile(dst); err == nil && sum == f.SHA256 {
				state[f.Path] = installedFile{Size: f.Size, SHA256: f.SHA256, ModTime: info.ModTime().UnixNano()}
				continue
			}
		}
		todo = append(todo, f)
		total += f.Size
	}
	if checking > 0 {
		fmt.Println()
	}
	// files we installed earlier that are no longer part of the game
	for p := range state {
		if !wanted[p] {
			_ = os.Remove(filepath.Join(installDir, filepath.FromSlash(p)))
			delete(state, p)
		}
	}
	saveState(installDir, state)

	if len(todo) == 0 {
		fmt.Printf("  %sUp to date%s (%s).\n", green, reset, m.Build)
		return nil
	}
	if len(state) == 0 {
		fmt.Printf("  Installing FANGS (%s): %s to download into\n  %s\n\n", m.Build, human(total), installDir)
	} else {
		fmt.Printf("  Update available: %d file(s), %s.\n\n", len(todo), human(total))
	}
	p := &progress{total: total, start: time.Now()}
	for _, f := range todo {
		dst := filepath.Join(installDir, filepath.FromSlash(f.Path))
		if err := download(base+"files/"+escapePath(f.Path), dst, f, p); err != nil {
			fmt.Println()
			return fmt.Errorf("downloading %s failed: %v\n  Run the launcher again to resume.", f.Path, err)
		}
		info, err := os.Stat(dst)
		if err != nil {
			return err
		}
		state[f.Path] = installedFile{Size: f.Size, SHA256: f.SHA256, ModTime: info.ModTime().UnixNano()}
		saveState(installDir, state)
	}
	p.draw(true)
	fmt.Printf("\n  %sDone!%s\n", green, reset)
	return nil
}

func escapePath(p string) string {
	segs := strings.Split(p, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// download fetches u into dst via dst.part, resuming a partial download, and checks the SHA-256.
func download(u, dst string, f manifestFile, p *progress) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	part := dst + ".part"
	h := sha256.New()
	var have int64
	if info, err := os.Stat(part); err == nil && info.Size() < f.Size {
		if pf, err := os.Open(part); err == nil {
			have, _ = io.Copy(h, pf)
			pf.Close()
		}
	} else {
		_ = os.Remove(part)
	}
	req, _ := http.NewRequest("GET", u, nil)
	if have > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	resp, err := longClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	flags := os.O_CREATE | os.O_WRONLY
	switch {
	case have > 0 && resp.StatusCode == http.StatusPartialContent:
		flags |= os.O_APPEND
		p.done += have
	case resp.StatusCode == http.StatusOK:
		flags |= os.O_TRUNC
		h.Reset()
		have = 0
	default:
		return fmt.Errorf("server answered %s", resp.Status)
	}
	out, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return err
	}
	buf := make([]byte, 1<<20)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := out.Write(buf[:n]); err != nil {
				out.Close()
				return err
			}
			h.Write(buf[:n])
			p.done += int64(n)
			p.file = f.Path
			p.draw(false)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			out.Close()
			return rerr
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != f.SHA256 {
		_ = os.Remove(part)
		return fmt.Errorf("file check failed (got %s..., want %s...)", got[:12], f.SHA256[:12])
	}
	_ = os.Remove(dst)
	return os.Rename(part, dst)
}

type progress struct {
	total, done int64
	start, last time.Time
	file        string
}

func (p *progress) draw(force bool) {
	now := time.Now()
	if !force && now.Sub(p.last) < 250*time.Millisecond {
		return
	}
	p.last = now
	frac := 0.0
	if p.total > 0 {
		frac = float64(p.done) / float64(p.total)
	}
	const width = 28
	n := int(frac * width)
	if n > width {
		n = width
	}
	speed := float64(p.done) / now.Sub(p.start).Seconds()
	name := p.file
	if len(name) > 32 {
		name = "..." + name[len(name)-29:]
	}
	fmt.Printf("\r  %s[%s%s]%s %5.1f%%  %s / %s  %s/s  %s%-32s%s ", teal, strings.Repeat("█", n), strings.Repeat("·", width-n), reset,
		frac*100, human(p.done), human(p.total), human(int64(speed)), dim, name, reset)
}

func human(n int64) string {
	f := float64(n)
	for _, u := range []string{"B", "KB", "MB", "GB"} {
		if f < 1024 || u == "GB" {
			if u == "B" {
				return fmt.Sprintf("%d %s", n, u)
			}
			return fmt.Sprintf("%.1f %s", f, u)
		}
		f /= 1024
	}
	return ""
}

// ---------------------------------------------------------------- self-update

func selfUpdate(base, self string, want *manifestFile) bool {
	if sum, err := hashFile(self); err != nil || sum == want.SHA256 {
		return false
	}
	fmt.Printf("  Updating the launcher...\n")
	tmp := self + ".new"
	p := &progress{total: want.Size, start: time.Now()}
	if err := download(base+"FangsCE.exe", tmp, *want, p); err != nil {
		fmt.Printf("\n  %sLauncher update failed (%v) - continuing with this one.%s\n", yellow, err, reset)
		return false
	}
	fmt.Println()
	// a running exe can be renamed on Windows, not overwritten
	if err := os.Rename(self, self+".old"); err != nil {
		fmt.Printf("  %sLauncher update failed (%v) - continuing with this one.%s\n", yellow, err, reset)
		return false
	}
	if err := os.Rename(tmp, self); err != nil {
		_ = os.Rename(self+".old", self)
		return false
	}
	_ = os.Chmod(self, 0o755) // (non-Windows test builds)
	cmd := exec.Command(self, os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		return false
	}
	_ = cmd.Wait() // keep the console attached until the new launcher is done
	return true
}

// ---------------------------------------------------------------- launch

func gameInstalled(st settings) bool {
	_, err := os.Stat(filepath.Join(st.InstallDir, "MOBA", "Binaries", "Win64", "MOBA-Win64-Shipping.exe"))
	return err == nil
}

func launch(st settings, m *manifest) error {
	exeRel, iniRel := "MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe", "FangsCE/Engine.ini"
	if m != nil {
		exeRel = m.Exe
		if m.EngineIni != "" {
			iniRel = m.EngineIni
		}
	}
	exe := filepath.Join(st.InstallDir, filepath.FromSlash(exeRel))
	// connection settings: Shipping builds read %LOCALAPPDATA%\MOBA\Saved, developer builds the game folder
	if ini, err := os.ReadFile(filepath.Join(st.InstallDir, filepath.FromSlash(iniRel))); err == nil {
		dirs := []string{filepath.Join(st.InstallDir, "MOBA", "Saved", "Config", "WindowsNoEditor")}
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			dirs = append(dirs, filepath.Join(d, "MOBA", "Saved", "Config", "WindowsNoEditor"))
		}
		for _, d := range dirs {
			if err := os.MkdirAll(d, 0o755); err == nil {
				_ = os.WriteFile(filepath.Join(d, "Engine.ini"), ini, 0o644)
			}
		}
	}
	if os.Getenv("FANGSCE_NO_LAUNCH") != "" { // tests
		fmt.Printf("\n  (not starting the game: FANGSCE_NO_LAUNCH)\n")
		return nil
	}
	pass := st.Secret
	if joinCode != "" {
		pass = joinCode + ":" + st.Secret
	}
	cmd := exec.Command(exe, "-TestUser="+st.Name, "-TestPass="+pass)
	cmd.Dir = filepath.Dir(exe)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("couldn't start the game: %v", err)
	}
	fmt.Printf("\n  %sStarting FANGS as %s - have fun!%s\n", green, st.Name, reset)
	time.Sleep(3 * time.Second)
	return nil
}
