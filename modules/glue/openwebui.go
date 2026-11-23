package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	openwebuiChunk  = "build/_app/immutable/chunks/BjRGu3Y4.js"
	openwebuiStock  = `ar.some(Kr=>Kr>0)&&(H&&H.state!=="recording"&&H.start(),r(M)||(l(M,!0),ut()),Br=Date.now()),r(M)&&Date.now()-Br>2e3&&(j=!0,H)){H.stop();return}`
	openwebuiApp    = "build/_app/immutable/entry/app.BpLUHdVz.js"
	openwebuiPage   = "build/index.html"
	openwebuiStamp  = "?v=8"
	openwebuiNeedle = "BjRGu3Y4.js"
)

func cmdOpenWebUICallScreen(args []string) error {
	if err := needArgs("openwebui-call-screen", args, 0); err != nil {
		return err
	}
	return openWebUICallScreen("/app")
}

func openWebUICallScreen(root string) error {
	chunk, err := os.ReadFile(filepath.Join(root, openwebuiChunk))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	text := string(chunk)
	if strings.Count(text, openwebuiStock) != 1 || strings.Contains(text, "__pax") {
		return fmt.Errorf("call screen is not the stock file")
	}
	appPath := filepath.Join(root, openwebuiApp)
	appRaw, err := os.ReadFile(appPath)
	if err != nil {
		return err
	}
	app := string(appRaw)
	if !strings.Contains(app, openwebuiNeedle+openwebuiStamp) {
		if strings.Count(app, openwebuiNeedle) != 1 {
			return fmt.Errorf("call screen import moved")
		}
		app = strings.Replace(app, openwebuiNeedle, openwebuiNeedle+openwebuiStamp, 1)
		if err := os.WriteFile(appPath, []byte(app), 0o644); err != nil {
			return err
		}
	}
	pagePath := filepath.Join(root, openwebuiPage)
	pageRaw, err := os.ReadFile(pagePath)
	if err != nil {
		return err
	}
	page := string(pageRaw)
	for _, name := range []string{"start.C0YxXQKT.js", "app.BpLUHdVz.js"} {
		if !strings.Contains(page, name+openwebuiStamp) {
			page = strings.ReplaceAll(page, name, name+openwebuiStamp)
		}
	}
	return os.WriteFile(pagePath, []byte(page), 0o644)
}

func cmdOpenWebUITools(args []string) error {
	if err := needArgs("openwebui-tools", args, 0); err != nil {
		return err
	}
	body, err := openWebUITools(os.Getenv("NEXUS_MCP_URL"), os.Getenv("OPENAI_API_KEY"))
	if err != nil {
		return err
	}
	fmt.Printf("%s\n", body)
	return nil
}

func openWebUITools(url, key string) (string, error) {
	url = strings.TrimSpace(url)
	key = stripQuotes(strings.TrimSpace(key))
	if url == "" || key == "" {
		return "", fmt.Errorf("nexus tool server missing")
	}
	body := jArr(jObj(
		jkv("type", jStr("mcp")),
		jkv("url", jStr(url)),
		jkv("auth_type", jStr("bearer")),
		jkv("key", jStr(key)),
		jkv("config", jObj(
			jkv("enable", jBool(true)),
			jkv("access_grants", jArr(jObj(
				jkv("principal_type", jStr("user")),
				jkv("principal_id", jStr("*")),
				jkv("permission", jStr("read")),
			))),
		)),
		jkv("info", jObj(
			jkv("id", jStr("nexus")),
			jkv("name", jStr("Nexus")),
			jkv("description", jStr("Search the NAS and return a temporary link.")),
		)),
	))
	return string(body.Marshal(jCompact)), nil
}
