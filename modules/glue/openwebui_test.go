package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenWebUICallScreenSkipsANewImage(t *testing.T) {
	if err := openWebUICallScreen(t.TempDir()); err != nil {
		t.Fatal(err)
	}
}

func TestOpenWebUICallScreenRejectsAPatchedChunk(t *testing.T) {
	root := t.TempDir()
	chunk := filepath.Join(root, openwebuiChunk)
	if err := os.MkdirAll(filepath.Dir(chunk), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(chunk, []byte(openwebuiStock+"__pax"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := openWebUICallScreen(root); err == nil {
		t.Fatal("patched chunk was accepted")
	}
}

func TestOpenWebUICallScreenStampsTheStockPage(t *testing.T) {
	root := t.TempDir()
	chunk := filepath.Join(root, openwebuiChunk)
	app := filepath.Join(root, openwebuiApp)
	page := filepath.Join(root, openwebuiPage)
	if err := os.MkdirAll(filepath.Dir(chunk), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(app), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(chunk, []byte("prefix"+openwebuiStock+"suffix"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(app, []byte("import(\""+openwebuiNeedle+"\")"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(page, []byte(`start.C0YxXQKT.js app.BpLUHdVz.js`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := openWebUICallScreen(root); err != nil {
		t.Fatal(err)
	}
	if err := openWebUICallScreen(root); err != nil {
		t.Fatal(err)
	}
	gotApp, err := os.ReadFile(app)
	if err != nil {
		t.Fatal(err)
	}
	if string(gotApp) != "import(\""+openwebuiNeedle+openwebuiStamp+"\")" {
		t.Fatalf("app %s", gotApp)
	}
	gotPage, err := os.ReadFile(page)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(gotPage), openwebuiStamp) != 2 {
		t.Fatalf("page %s", gotPage)
	}
}

func TestOpenWebUIToolsUsesTheChatKey(t *testing.T) {
	body, err := openWebUITools("http://198.51.100.90:8093/mcp/nexus", "placeholder-key")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`"type":"mcp"`,
		`"url":"http://198.51.100.90:8093/mcp/nexus"`,
		`"auth_type":"bearer"`,
		`"key":"placeholder-key"`,
		`"principal_id":"*"`,
		`"id":"nexus"`,
		`"name":"Nexus"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %s in %s", want, body)
		}
	}
	if strings.Contains(body, "legacy") || strings.Contains(body, "archive") {
		t.Fatalf("old catalog connection %s", body)
	}
}

func TestOpenWebUIToolsRefusesAnEmptyKey(t *testing.T) {
	if _, err := openWebUITools("http://198.51.100.90:8093/mcp/nexus", ""); err == nil {
		t.Fatal("empty key was accepted")
	}
	if _, err := openWebUITools("", "placeholder-key"); err == nil {
		t.Fatal("empty url was accepted")
	}
}
