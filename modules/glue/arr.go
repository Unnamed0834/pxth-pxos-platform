package main

import (
	"os"
	"strings"
	"unicode"
)

func cmdBazarrAuth(args []string) error {
	if err := needArgs("bazarr-auth", args, 1); err != nil {
		return err
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	lines := splitKeep(string(raw))
	inAuth := false
	changed := false
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(line, "auth:") {
			inAuth = true
			out = append(out, line)
			continue
		}
		if inAuth && line != "" && !unicode.IsSpace(rune(line[0])) {
			inAuth = false
		}
		if inAuth && strings.HasPrefix(line, "  type:") {
			out = append(out, "  type: none\n")
			changed = true
			inAuth = false
			continue
		}
		out = append(out, line)
	}
	if !changed {
		return nil
	}
	return os.WriteFile(args[0], []byte(strings.Join(out, "")), 0o644)
}

func splitKeep(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\n':
			lines = append(lines, s[start:i+1])
			start = i + 1
		case '\r':
			if i+1 < len(s) && s[i+1] == '\n' {
				lines = append(lines, s[start:i+2])
				i++
				start = i + 1
			} else {
				lines = append(lines, s[start:i+1])
				start = i + 1
			}
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func cmdJDownloaderAPI(args []string) error {
	if err := needArgs("jdownloader-api", args, 1); err != nil {
		return err
	}
	data, err := readJSONFile(args[0])
	if err != nil {
		return err
	}
	data.Set("deprecatedapienabled", jBool(true))
	data.Set("deprecatedapilocalhostonly", jBool(false))
	data.Set("deprecatedapiport", jNum("3128"))
	return writeJSONFile(args[0], data, jSpaced, true)
}
