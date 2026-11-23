package main

import (
	"strings"
	"testing"
)

func TestFluxerBoardThemeSetsAccent(t *testing.T) {
	in := `{"branding":{"product_name":"example chat","theme_color":"#000000"},"setup":{"configured":true}}`
	out, changed, err := fluxerBoardTheme(in)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("theme color was already the board accent")
	}
	if !strings.Contains(out, `"theme_color":"`+boardAccent+`"`) || !strings.Contains(out, `"product_name":"example chat"`) {
		t.Fatalf("branding %s", out)
	}
	again, changed, err := fluxerBoardTheme(out)
	if err != nil {
		t.Fatal(err)
	}
	if changed || again != out {
		t.Fatalf("second pass changed %v %s", changed, again)
	}
}

func TestFluxerBoardThemeLeavesEmpty(t *testing.T) {
	out, changed, err := fluxerBoardTheme("  ")
	if err != nil {
		t.Fatal(err)
	}
	if changed || out != "  " {
		t.Fatalf("empty became %q changed %v", out, changed)
	}
}
