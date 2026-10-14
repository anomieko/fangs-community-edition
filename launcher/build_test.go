package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeBuild(t *testing.T, dir, build, marker string) {
	t.Helper()
	v := filepath.Join(dir, "MOBA", "Content", "Data")
	if err := os.MkdirAll(v, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(v, "version.txt"), []byte(build+"\r\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "marker"), []byte(marker), 0o644)
}

func marker(dir string) string { b, _ := os.ReadFile(filepath.Join(dir, "marker")); return string(b) }

func TestSwitchBuild(t *testing.T) {
	root := t.TempDir()
	inst := filepath.Join(root, "FANGS")
	writeBuild(t, inst, "alpha7.0.7.51", "aug")

	// server switches to Feb: Aug is set aside, an empty folder waits for the download
	if err := switchBuild(inst, "Playtest021523v1_v0_0_02"); err != nil {
		t.Fatal(err)
	}
	if marker(parkedDir(inst, "alpha7.0.7.51")) != "aug" || marker(inst) != "" {
		t.Fatal("Aug not set aside")
	}
	writeBuild(t, inst, "Playtest021523v1_v0_0_02", "feb") // what the download would leave

	// back to Aug: folders swap, nothing to download
	if err := switchBuild(inst, "alpha7.0.7.51"); err != nil {
		t.Fatal(err)
	}
	if marker(inst) != "aug" || marker(parkedDir(inst, "Playtest021523v1_v0_0_02")) != "feb" {
		t.Fatal("swap back failed")
	}
	// same build: nothing happens; untrusted names: nothing happens
	if err := switchBuild(inst, "alpha7.0.7.51"); err != nil || marker(inst) != "aug" {
		t.Fatal("same build touched the folder")
	}
	if err := switchBuild(inst, "../evil"); err != nil || marker(inst) != "aug" {
		t.Fatal("untrusted build name used as a folder name")
	}
}
