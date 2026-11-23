package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSubuidWalkDoesNotFollowSymlinks(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(real, "file"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	var got []string
	prev := lchownFn
	lchownFn = func(path string, _, _ int) error {
		got = append(got, path)
		return nil
	}
	t.Cleanup(func() { lchownFn = prev })
	if err := subuidWalk(root, 0, 1<<30, 1); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, path := range got {
		seen[path] = true
	}
	for _, path := range []string{root, real, filepath.Join(real, "file"), filepath.Join(root, "link")} {
		if !seen[path] {
			t.Fatalf("missing %s in %v", path, got)
		}
	}
	if seen[filepath.Join(root, "link", "file")] {
		t.Fatalf("followed symlink: %v", got)
	}
}
