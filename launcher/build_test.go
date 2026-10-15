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

func buildManifest(build string) *manifest {
	return &manifest{Build: build, Files: []manifestFile{{Path: "MOBA/Content/Data/version.txt"}, {Path: "marker"}}}
}

func TestSwitchBuild(t *testing.T) {
	root := t.TempDir()
	inst := filepath.Join(root, "FANGS")
	writeBuild(t, inst, "alpha7.0.7.51", "aug")

	// server switches to Feb: Aug is set aside, an empty folder waits for the download
	if err := switchBuild(inst, buildManifest("Playtest021523v1_v0_0_02")); err != nil {
		t.Fatal(err)
	}
	if marker(parkedDir(inst, "alpha7.0.7.51")) != "aug" || marker(inst) != "" {
		t.Fatal("Aug not set aside")
	}
	writeBuild(t, inst, "Playtest021523v1_v0_0_02", "feb") // what the download would leave

	// back to Aug: folders swap, nothing to download
	if err := switchBuild(inst, buildManifest("alpha7.0.7.51")); err != nil {
		t.Fatal(err)
	}
	if marker(inst) != "aug" || marker(parkedDir(inst, "Playtest021523v1_v0_0_02")) != "feb" {
		t.Fatal("swap back failed")
	}
	// same build: nothing happens; untrusted names: nothing happens
	if err := switchBuild(inst, buildManifest("alpha7.0.7.51")); err != nil || marker(inst) != "aug" {
		t.Fatal("same build touched the folder")
	}
	if err := switchBuild(inst, buildManifest("../evil")); err != nil || marker(inst) != "aug" {
		t.Fatal("untrusted build name used as a folder name")
	}
}

func TestSwitchBuildLeavesSharedFolders(t *testing.T) {
	// an older launcher installed straight into a folder with other things in it (Downloads): never moved
	inst := filepath.Join(t.TempDir(), "Downloads")
	writeBuild(t, inst, "alpha7.0.7.51", "aug")
	os.WriteFile(filepath.Join(inst, "holiday.jpg"), []byte("x"), 0o644)
	if err := switchBuild(inst, buildManifest("Playtest021523v1_v0_0_02")); err != nil {
		t.Fatal(err)
	}
	if marker(inst) != "aug" || exists(parkedDir(inst, "alpha7.0.7.51")) {
		t.Fatal("a folder with other things in it was moved")
	}
}
