package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

const (
	reolinkInput    = "-fflags nobuffer -flags low_delay -use_wallclock_as_timestamps 1 -timeout {timeout} -i {input}"
	reolinkTLSInput = "-fflags nobuffer -flags low_delay -use_wallclock_as_timestamps 1 -verify 0 -timeout {timeout} -i {input}"
	reolinkTLSSub   = "-fflags nobuffer -flags low_delay -verify 0 -timeout {timeout} -i {input}"
	nvrMainExtra    = "#video=copy#audio=copy#audio=opus"
)

type nvrSpec struct {
	FFmpeg  string      `json:"ffmpeg"`
	Cameras []nvrCamera `json:"cameras"`
}

type nvrCamera struct {
	Name string `json:"name"`
	Host string `json:"host"`
	TLS  bool   `json:"tls"`
}

func cmdGo2rtc(args []string) error {
	if err := needArgs("go2rtc", args, 4); err != nil {
		return err
	}
	specPath, passwordPath, yamlPath, urlsPath := args[0], args[1], args[2], args[3]
	raw, err := os.ReadFile(specPath)
	if err != nil {
		return err
	}
	var spec nvrSpec
	if err := json.Unmarshal(raw, &spec); err != nil {
		return err
	}
	secret, err := os.ReadFile(passwordPath)
	if err != nil {
		return err
	}
	yamlText, urlsText, err := renderGo2rtc(spec, loadPasswords(string(secret)))
	if err != nil {
		return err
	}
	if err := os.WriteFile(yamlPath, []byte(yamlText), 0o644); err != nil {
		return err
	}
	return os.WriteFile(urlsPath, []byte(urlsText), 0o644)
}

func cmdInject(args []string) error {
	if err := needArgs("inject", args, 2); err != nil {
		return err
	}
	config, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	urls, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	return os.WriteFile(args[0], []byte(injectNVR(string(config), string(urls))), 0o644)
}

func loadPasswords(text string) map[string]string {
	out := map[string]string{}
	for _, raw := range splitLines(text) {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		name, password, _ := strings.Cut(line, "=")
		out[name] = password
	}
	return out
}

func streamURL(host, password, channel, extra string, tls bool) string {
	scheme := "http"
	if tls {
		scheme = "https"
	}
	return "ffmpeg:" + scheme + "://" + host + "/flv?port=1935&app=bcs&stream=" + channel + ".bcs&user=admin&password=" + password + extra
}

func yamlSingleQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

type nvrStream struct {
	name   string
	url    string
	go2rtc string
}

func cameraStreams(cam nvrCamera, password string) []nvrStream {
	mainTemplate := "reolink"
	subTemplate := ""
	if cam.TLS {
		mainTemplate = "reolink_tls"
		subTemplate = "reolink_tls_sub"
	}
	mainURL := streamURL(cam.Host, password, "channel0_main", nvrMainExtra, cam.TLS)
	subURL := streamURL(cam.Host, password, "channel0_ext", "", cam.TLS)
	mainGo := mainURL + "#input=" + mainTemplate
	subGo := subURL
	if subTemplate != "" {
		subGo = subURL + "#input=" + subTemplate
	}
	return []nvrStream{
		{cam.Name, mainURL, mainGo},
		{cam.Name + "_sub", subURL, subGo},
	}
}

func renderGo2rtc(spec nvrSpec, passwords map[string]string) (string, string, error) {
	lines := []string{
		"api:",
		`  listen: ":1984"`,
		"rtsp:",
		`  listen: ":8554"`,
		"webrtc:",
		`  listen: ":8555"`,
		"ffmpeg:",
		"  bin: " + spec.FFmpeg,
		"  reolink: " + yamlSingleQuote(reolinkInput),
		"  reolink_tls: " + yamlSingleQuote(reolinkTLSInput),
		"  reolink_tls_sub: " + yamlSingleQuote(reolinkTLSSub),
		"streams:",
	}
	var urls []string
	for _, cam := range spec.Cameras {
		password, ok := passwords[cam.Name]
		if !ok {
			return "", "", fmt.Errorf("nvr-render: no password for %s", cam.Name)
		}
		for _, stream := range cameraStreams(cam, password) {
			lines = append(lines, "  "+stream.name+": "+yamlSingleQuote(stream.go2rtc))
			urls = append(urls, stream.name+"="+stream.url)
		}
	}
	return strings.Join(lines, "\n") + "\n", strings.Join(urls, "\n") + "\n", nil
}

func injectNVR(configText, urlsText string) string {
	type pair struct {
		name string
		url  string
	}
	var pairs []pair
	for _, raw := range splitLines(urlsText) {
		if raw == "" || !strings.Contains(raw, "=") {
			continue
		}
		name, url, _ := strings.Cut(raw, "=")
		pairs = append(pairs, pair{name, url})
	}
	sort.Slice(pairs, func(i, j int) bool {
		return len(pairs[i].name) > len(pairs[j].name)
	})
	for _, p := range pairs {
		configText = strings.ReplaceAll(configText, "__NVR__:"+p.name+"__", p.url)
	}
	return configText
}
