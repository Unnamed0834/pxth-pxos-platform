package main

import (
	"fmt"
	"os"
	"strings"
)

func cmdOpenCodeConfig(args []string) error {
	if err := needArgs("opencode-config", args, 1); err != nil {
		return err
	}
	cfg, err := readJSONFile(args[0])
	if err != nil {
		return err
	}
	if keysPath := os.Getenv("PAXOS_API_KEYS"); keysPath != "" {
		token, err := memoryToken(keysPath)
		if err != nil {
			return err
		}
		providers, err := cfg.setDefaultObj("providers")
		if err != nil {
			return err
		}
		gateway, err := providers.setDefaultObj("gateway")
		if err != nil {
			return err
		}
		settings, err := gateway.setDefaultObj("settings")
		if err != nil {
			return err
		}
		settings.Set("apiKey", jStr(token))
		if memory, err := mcpObject(&cfg, "memory"); err != nil {
			return err
		} else if memory != nil {
			memory.Set("headers", bearerHeader(token))
		}
		if indexPath := os.Getenv("PAXOS_CODEBASE_INDEX"); indexPath != "" {
			index, err := readJSONFile(indexPath)
			if err != nil {
				return err
			}
			if custom := index.ObjAt("customProvider"); custom != nil {
				custom.Set("apiKey", jStr(token))
			}
			if err := writeJSONFile(indexPath, index, jIndent, true); err != nil {
				return err
			}
		}
	}
	if path := os.Getenv("PAXOS_MCP_BEARERS"); path != "" {
		found, err := parseEnvLast(path)
		if err != nil {
			return err
		}
		archive := found["ARCHIVE_MCP_BEARER"]
		if archive == "" {
			return fmt.Errorf("mcp bearer file is missing an archive bearer")
		}
		entry, err := mcpObject(&cfg, "archive")
		if err != nil {
			return err
		}
		if entry != nil {
			entry.Set("headers", bearerHeader(archive))
		}
	}
	return writeJSONFile(args[0], cfg, jIndent, true)
}

func bearerHeader(token string) JVal {
	return jObj(jkv("Authorization", jStr("Bearer "+token)))
}

func memoryToken(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	for _, line := range splitLines(string(raw)) {
		parts := strings.Fields(line)
		if len(parts) >= 4 && parts[2] == "yes" && parts[3] != "" {
			return parts[1], nil
		}
	}
	return "", fmt.Errorf("api key file has no memory=yes token")
}

func envKey(path, name string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := ""
	for _, line := range splitLines(string(raw)) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, val, _ := strings.Cut(line, "=")
		if strings.TrimSpace(key) == name {
			value = stripQuotes(val)
		}
	}
	return value, nil
}

func mcpObject(cfg *JVal, name string) (*JVal, error) {
	mcp, ok := lookup(cfg, "mcp")
	if !ok || mcp.Kind == kindNull {
		return nil, nil
	}
	if mcp.Kind != kindObj {
		return nil, fmt.Errorf("mcp is not an object")
	}
	return cfg.ObjAt("mcp").ObjAt(name), nil
}

func lookup(v *JVal, key string) (JVal, bool) {
	if v == nil || v.Kind != kindObj {
		return JVal{}, false
	}
	for _, pair := range v.Obj {
		if pair.Key == key {
			return pair.Val, true
		}
	}
	return JVal{}, false
}

func applyBearer(cfg *JVal, envName, keyName, entryName, missing string) error {
	path := os.Getenv(envName)
	if path == "" {
		return nil
	}
	token, err := envKey(path, keyName)
	if err != nil {
		return err
	}
	entry, err := mcpObject(cfg, entryName)
	if err != nil {
		return err
	}
	if entry == nil {
		return nil
	}
	if token == "" {
		return fmt.Errorf("%s", missing)
	}
	entry.Set("headers", bearerHeader(token))
	return nil
}
