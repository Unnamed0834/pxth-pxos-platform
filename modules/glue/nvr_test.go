package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlainAndTLSURLsAndTemplates(t *testing.T) {
	spec := nvrSpec{
		FFmpeg: "/bin/ffmpeg",
		Cameras: []nvrCamera{
			{Name: "drive-way", Host: "198.51.100.50", TLS: false},
			{Name: "rack", Host: "198.51.100.53", TLS: true},
		},
	}
	passwords := map[string]string{"drive-way": "placeholder-secret-a", "rack": "placeholder-secret-b"}
	yamlText, urlsText, err := renderGo2rtc(spec, passwords)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"placeholder-secret-a",
		"placeholder-secret-b",
		"ffmpeg:http://198.51.100.50/flv?",
		"stream=channel0_main.bcs",
		"#input=reolink",
		"ffmpeg:https://198.51.100.53/flv?",
		"#input=reolink_tls",
		"#input=reolink_tls_sub",
		"-verify 0",
	} {
		if !strings.Contains(yamlText, want) {
			t.Fatalf("yaml missing %q\n%s", want, yamlText)
		}
	}
	var sub string
	for _, line := range strings.Split(yamlText, "\n") {
		if strings.HasPrefix(line, "  drive-way_sub:") {
			sub = line
		}
	}
	if sub == "" || strings.Contains(sub, "#input=") {
		t.Fatalf("plain sub should have no input template: %q", sub)
	}
	urls := map[string]string{}
	for _, line := range splitLines(urlsText) {
		if line == "" {
			continue
		}
		name, url, _ := strings.Cut(line, "=")
		urls[name] = url
	}
	if !strings.HasSuffix(urls["drive-way"], "#audio=opus") {
		t.Fatalf("main url %q", urls["drive-way"])
	}
	if strings.Contains(urls["drive-way"], "#input=") || strings.Contains(urls["rack_sub"], "#input=") {
		t.Fatalf("frigate urls include an input template: %#v", urls)
	}
	if !strings.HasPrefix(urls["rack"], "ffmpeg:https://") {
		t.Fatalf("rack url %q", urls["rack"])
	}
}

func TestInjectReplacesLongerNamesFirst(t *testing.T) {
	text := "main: '__NVR__:drive-way__'\nsub: '__NVR__:drive-way_sub__'\n"
	urls := "drive-way=http://main\ndrive-way_sub=http://sub\n"
	if got := injectNVR(text, urls); got != "main: 'http://main'\nsub: 'http://sub'\n" {
		t.Fatalf("got %q", got)
	}
}

func TestCLIRoundtrip(t *testing.T) {
	root := t.TempDir()
	spec := filepath.Join(root, "spec.json")
	passwords := filepath.Join(root, "passwords")
	yamlPath := filepath.Join(root, "go2rtc.yaml")
	urlsPath := filepath.Join(root, "urls.env")
	config := filepath.Join(root, "frigate.yml")
	raw, _ := json.Marshal(map[string]any{
		"ffmpeg": "/bin/ffmpeg",
		"cameras": []map[string]any{{
			"name": "rack",
			"host": "198.51.100.53",
			"tls":  true,
		}},
	})
	if err := os.WriteFile(spec, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(passwords, []byte("rack=placeholder-secret\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config, []byte("streams:\n  rack: '__NVR__:rack__'\n  rack_sub: '__NVR__:rack_sub__'\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := cmdGo2rtc([]string{spec, passwords, yamlPath, urlsPath}); err != nil {
		t.Fatal(err)
	}
	yamlText, _ := os.ReadFile(yamlPath)
	specText, _ := os.ReadFile(spec)
	if !strings.Contains(string(yamlText), "placeholder-secret") || strings.Contains(string(specText), "placeholder-secret") {
		t.Fatal("password leaked into the spec or missed the yaml")
	}
	if err := cmdInject([]string{config, urlsPath}); err != nil {
		t.Fatal(err)
	}
	rendered, _ := os.ReadFile(config)
	text := string(rendered)
	if strings.Contains(text, "__NVR__") || !strings.Contains(text, "placeholder-secret") || strings.Contains(text, "#input=") {
		t.Fatalf("injected config: %s", text)
	}
}

func TestMissingPasswordExits(t *testing.T) {
	_, _, err := renderGo2rtc(nvrSpec{
		FFmpeg:  "/bin/ffmpeg",
		Cameras: []nvrCamera{{Name: "rack", Host: "198.51.100.1", TLS: true}},
	}, map[string]string{})
	if err == nil || !strings.Contains(err.Error(), "rack") {
		t.Fatalf("got %v", err)
	}
}
