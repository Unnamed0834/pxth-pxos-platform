package main

import (
	"os"
	"strings"
	"unicode"
)

func osReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func osWriteFile(path string, data []byte, mode os.FileMode) error {
	return os.WriteFile(path, data, mode)
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return strings.Split(s, "\n")
}

func stripQuotes(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `"`)
	return strings.Trim(s, "'")
}

func envValue(path, name string) (string, error) {
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	prefix := name + "="
	for _, line := range splitLines(string(b)) {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return stripQuotes(line[len(prefix):]), nil
		}
	}
	return "", nil
}

func parseEnvLast(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	env := map[string]string{}
	for _, line := range splitLines(string(b)) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, val, _ := strings.Cut(line, "=")
		env[strings.TrimSpace(key)] = stripQuotes(val)
	}
	return env, nil
}

type envPair struct {
	Key string
	Val string
}

func parseEnvResume(path string) ([]envPair, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var pairs []envPair
	for _, raw := range splitLines(string(b)) {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, val, _ := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if strings.HasPrefix(key, "export ") {
			key = strings.TrimSpace(key[len("export "):])
		}
		val = strings.TrimSpace(val)
		if len(val) >= 2 && val[0] == val[len(val)-1] && (val[0] == '"' || val[0] == '\'') {
			val = val[1 : len(val)-1]
		}
		pairs = append(pairs, envPair{Key: key, Val: val})
	}
	return pairs, nil
}

func pyQuote(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' {
			b.WriteByte(c)
		} else {
			const hex = "0123456789ABCDEF"
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0x0f])
		}
	}
	return b.String()
}

func htmlEscape(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&#x27;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func rstrip(s string) string {
	return strings.TrimRightFunc(s, unicode.IsSpace)
}

func replaceFirst(s, old, repl string) (string, bool) {
	i := strings.Index(s, old)
	if i < 0 {
		return s, false
	}
	return s[:i] + repl + s[i+len(old):], true
}
