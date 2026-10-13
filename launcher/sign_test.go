package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestManifestSignature(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	good := []byte(`{"build":"b","exe":"MOBA/x.exe","files":[{"path":"MOBA/x.exe","size":1,"sha256":"00"}]}`)
	files := map[string]string{
		"/m.json":       string(good),
		"/m.json.sig":   base64.StdEncoding.EncodeToString(ed25519.Sign(priv, good)),
		"/bad.json":     strings.Replace(string(good), `"size":1`, `"size":2`, 1),
		"/bad.json.sig": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, good)),
		"/nosig.json":   string(good),
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := files[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(body))
	}))
	defer srv.Close()

	pubKey = base64.StdEncoding.EncodeToString(pub)
	defer func() { pubKey = "" }()
	if _, err := fetchManifest(srv.URL + "/m.json"); err != nil {
		t.Fatalf("signed file list rejected: %v", err)
	}
	if _, err := fetchManifest(srv.URL + "/bad.json"); err == nil {
		t.Fatal("tampered file list accepted")
	}
	if _, err := fetchManifest(srv.URL + "/nosig.json"); err == nil {
		t.Fatal("unsigned file list accepted")
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	pubKey = base64.StdEncoding.EncodeToString(other)
	if _, err := fetchManifest(srv.URL + "/m.json"); err == nil {
		t.Fatal("file list signed with another key accepted")
	}
}
