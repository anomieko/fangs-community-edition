package main

import (
	"bufio"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseInvite(t *testing.T) {
	inv := makeInvite("203.0.113.10:8080", "abc_DEF-123")
	for _, in := range []string{inv, "  " + strings.ToLower(inv) + "\r\n", "http://203.0.113.10:8080/download/abc_DEF-123/FangsCE.exe"} {
		srv, code, ok := parseInvite(in)
		if !ok || srv != "203.0.113.10:8080" || code != "abc_DEF-123" {
			t.Fatalf("%q -> %q %q %v", in, srv, code, ok)
		}
	}
	for _, in := range []string{"", "hello", "FCE-", "FCE-!!!!", makeInvite("evil host", "x"), makeInvite("h:1", "a/b"),
		"http://203.0.113.10:8080/FangsCE.exe"} {
		if _, _, ok := parseInvite(in); ok {
			t.Fatalf("accepted %q", in)
		}
	}
}

func TestUseInvite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/download/good/manifest.json" {
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()
	host := strings.TrimPrefix(ts.URL, "http://")
	defer func(s, c string) { server, joinCode = s, c }(server, joinCode)
	cfg := filepath.Join(t.TempDir(), "launcher.json")

	// public build: garbage and a refused code are asked again, the good one is kept
	server, joinCode = "127.0.0.1:8080", ""
	stdin = bufio.NewReader(strings.NewReader("nope\n" + makeInvite(host, "bad") + "\n" + makeInvite(host, "good") + "\n"))
	st := settings{InstallDir: "x", Name: "tester", Secret: "s"}
	if err := useInvite(cfg, &st); err != nil {
		t.Fatal(err)
	}
	if server != host || joinCode != "good" {
		t.Fatalf("using %s %s", server, joinCode)
	}
	if saved, err := loadSettings(cfg); err != nil || saved.Server != host || saved.JoinCode != "good" {
		t.Fatalf("saved %+v %v", saved, err)
	}

	// next start: no question
	server, joinCode = "127.0.0.1:8080", ""
	stdin = bufio.NewReader(strings.NewReader(""))
	st, _ = loadSettings(cfg)
	if err := useInvite(cfg, &st); err != nil || joinCode != "good" {
		t.Fatalf("remembered invite not used: %v %s", err, joinCode)
	}

	// a baked-in launcher wins and is remembered for the public build
	server, joinCode = "198.51.100.7:8080", "baked"
	if err := useInvite(cfg, &st); err != nil || joinCode != "baked" {
		t.Fatal("baked-in values not used")
	}
	if saved, _ := loadSettings(cfg); saved.Server != "198.51.100.7:8080" || saved.JoinCode != "baked" {
		t.Fatalf("baked-in values not remembered: %+v", saved)
	}
}

func TestInviteMatchesScript(t *testing.T) {
	// server/invite.sh output for 203.0.113.10 and join code test_code-1
	if srv, code, ok := parseInvite("FCE-GIYDGLRQFYYTCMZOGEYDUOBQHAYC65DFON2F6Y3PMRSS2MI"); !ok || srv != "203.0.113.10:8080" || code != "test_code-1" {
		t.Fatalf("%q %q %v", srv, code, ok)
	}
}
