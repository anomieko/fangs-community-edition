package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// chunkServer serves a file as the backend does: whole at files/<path> (with Range), in gzipped pieces at
// chunks/<sha256>.gz. It counts piece requests; broken(sha) can make a piece fail.
type chunkServer struct {
	*httptest.Server
	mu       sync.Mutex
	gets     map[string]int
	ranges   int
	noChunks bool
	broken   func(sha string, try int) bool
}

func newChunkServer(t *testing.T, path string, data []byte, f manifestFile) *chunkServer {
	s := &chunkServer{gets: map[string]int{}}
	gz := map[string][]byte{}
	off := int64(0)
	for _, c := range f.Chunks {
		var b bytes.Buffer
		zw := gzip.NewWriter(&b)
		zw.Write(data[off : off+c.Size])
		zw.Close()
		gz[c.SHA256] = b.Bytes()
		off += c.Size
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept-Encoding") != "identity" {
			t.Errorf("%s asked for Accept-Encoding %q", r.URL.Path, r.Header.Get("Accept-Encoding"))
		}
		if sha, ok := strings.CutPrefix(r.URL.Path, "/chunks/"); ok {
			sha = strings.TrimSuffix(sha, ".gz")
			s.mu.Lock()
			s.gets[sha]++
			try, noChunks := s.gets[sha], s.noChunks
			s.mu.Unlock()
			b, ok := gz[sha]
			if !ok || noChunks {
				http.NotFound(w, r)
				return
			}
			if s.broken != nil && s.broken(sha, try) {
				b = append([]byte{}, b...)
				b[len(b)/2] ^= 0xff
			}
			w.Write(b)
			return
		}
		if r.URL.Path == "/files/"+path {
			s.mu.Lock()
			s.ranges++
			s.mu.Unlock()
			http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(s.Close)
	return s
}

// testFile: half compressible, half random, in pieces of 1000 bytes (the last one shorter).
func testFile() ([]byte, manifestFile) {
	data := make([]byte, 10500)
	rand.New(rand.NewSource(1)).Read(data[5000:])
	for i := range 5000 {
		data[i] = byte('a' + i/7%26) // compressible, and no two pieces alike
	}
	sum := sha256.Sum256(data)
	f := manifestFile{Path: "MOBA/Content/Paks/big.pak", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}
	for off := 0; off < len(data); off += 1000 {
		end := min(off+1000, len(data))
		s := sha256.Sum256(data[off:end])
		f.Chunks = append(f.Chunks, chunk{SHA256: hex.EncodeToString(s[:]), Size: int64(end - off), CSize: 100})
	}
	return data, f
}

func fetchInto(t *testing.T, s *chunkServer, f manifestFile) (string, error) {
	t.Helper()
	dst := filepath.Join(t.TempDir(), "big.pak")
	return dst, downloadChunked(s.URL+"/", dst, f, &progress{total: downloadSize(f)})
}

func checkFile(t *testing.T, dst string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(dst)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("file differs (%d bytes, want %d, err %v)", len(got), len(want), err)
	}
	if _, err := os.Stat(dst + ".part"); !os.IsNotExist(err) {
		t.Fatal(".part left behind")
	}
}

func TestDownloadChunked(t *testing.T) {
	data, f := testFile()
	s := newChunkServer(t, f.Path, data, f)
	dst, err := fetchInto(t, s, f)
	if err != nil {
		t.Fatal(err)
	}
	checkFile(t, dst, data)
	if len(s.gets) != len(f.Chunks) || s.ranges != 0 {
		t.Fatalf("pieces fetched %d (want %d), whole-file requests %d", len(s.gets), len(f.Chunks), s.ranges)
	}
}

func TestDownloadChunkedResumes(t *testing.T) {
	data, f := testFile()
	s := newChunkServer(t, f.Path, data, f)
	dst := filepath.Join(t.TempDir(), "big.pak")
	// an earlier start left pieces 0-6 (piece 3 damaged) and half of piece 7; a whole-file .part from an older
	// launcher looks the same
	part := append([]byte{}, data[:7500]...)
	part[3500] ^= 0xff
	os.WriteFile(dst+".part", part, 0o644)
	if err := downloadChunked(s.URL+"/", dst, f, &progress{total: downloadSize(f)}); err != nil {
		t.Fatal(err)
	}
	checkFile(t, dst, data)
	for i, c := range f.Chunks {
		want := 0
		if i == 3 || i >= 7 {
			want = 1
		}
		if s.gets[c.SHA256] != want {
			t.Errorf("piece %d fetched %d times, want %d", i, s.gets[c.SHA256], want)
		}
	}
}

func TestDownloadChunkedLongerPart(t *testing.T) {
	data, f := testFile()
	s := newChunkServer(t, f.Path, data, f)
	dst := filepath.Join(t.TempDir(), "big.pak")
	os.WriteFile(dst+".part", append(append([]byte{}, data...), "junk"...), 0o644)
	if err := downloadChunked(s.URL+"/", dst, f, &progress{total: downloadSize(f)}); err != nil {
		t.Fatal(err)
	}
	checkFile(t, dst, data)
	if len(s.gets) != 0 {
		t.Fatalf("fetched %d pieces of a complete .part", len(s.gets))
	}
}

func TestDownloadChunkedRetriesBadPiece(t *testing.T) {
	data, f := testFile()
	s := newChunkServer(t, f.Path, data, f)
	bad := f.Chunks[4].SHA256
	s.broken = func(sha string, try int) bool { return sha == bad && try < 3 } // third try is good
	dst, err := fetchInto(t, s, f)
	if err != nil {
		t.Fatal(err)
	}
	checkFile(t, dst, data)

	s2 := newChunkServer(t, f.Path, data, f)
	s2.broken = func(sha string, try int) bool { return sha == bad } // never good: fails, keeps the rest
	dst, err = fetchInto(t, s2, f)
	if err == nil {
		t.Fatal("a piece that never arrives intact didn't fail the download")
	}
	if s2.gets[bad] != 3 {
		t.Fatalf("bad piece tried %d times, want 3", s2.gets[bad])
	}
	if _, err := os.Stat(dst); !os.IsNotExist(err) {
		t.Fatal("a broken download replaced the file")
	}
}

func TestDownloadChunkedWithoutPieces(t *testing.T) {
	// a server that has no pieces (not built yet): each piece comes as a range of the whole file
	data, f := testFile()
	s := newChunkServer(t, f.Path, data, f)
	s.noChunks = true
	dst, err := fetchInto(t, s, f)
	if err != nil {
		t.Fatal(err)
	}
	checkFile(t, dst, data)
	if s.ranges != len(f.Chunks) {
		t.Fatalf("%d range requests, want %d", s.ranges, len(f.Chunks))
	}
}
