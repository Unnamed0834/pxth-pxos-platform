package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestJellyfinSeedWritesProviderAndLoginButton(t *testing.T) {
	root := t.TempDir()
	issuer := "https://auth.example.test"
	if err := os.Mkdir(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "system.xml"), []byte("<ServerConfiguration><QuickConnectAvailable>false</QuickConnectAvailable></ServerConfiguration>"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(root, "config", "branding.xml"), []byte("<BrandingOptions><LoginDisclaimer /><CustomCss /></BrandingOptions>"), 0o644); err != nil {
		t.Fatal(err)
	}
	seed := func(auto bool) {
		t.Helper()
		if err := jellyfinSeed(root, "placeholder-secret", issuer, "jellyfin", "https://jellyfin.example.test", "owner,example", "owner", auto, ""); err != nil {
			t.Fatal(err)
		}
	}
	seed(true)
	xml, err := os.ReadFile(filepath.Join(root, "plugins", "configurations", "SSO-Auth.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(xml), "<OidEndpoint>"+issuer+"</OidEndpoint>") {
		t.Fatalf("xml %s", xml)
	}
	if !strings.Contains(string(xml), "<string>owner</string><string>example</string>") {
		t.Fatalf("roles %s", xml)
	}
	system, _ := os.ReadFile(filepath.Join(root, "config", "system.xml"))
	if !strings.Contains(string(system), "QuickConnectAvailable>true<") {
		t.Fatalf("system %s", system)
	}
	brandRaw, _ := os.ReadFile(filepath.Join(root, "config", "branding.xml"))
	brand := string(brandRaw)
	if !strings.Contains(brand, "sso/OID/start/authelia") || !strings.Contains(brand, "paxSsoAt") || !strings.Contains(brand, "https://jellyfin.example.test/sso/OID/start/authelia") {
		t.Fatalf("brand %s", brand)
	}

	moved := strings.ReplaceAll(brand, "https://jellyfin.example.test", "https://jellyfin.old.example.test")
	if err := os.WriteFile(filepath.Join(root, "config", "branding.xml"), []byte(moved), 0o644); err != nil {
		t.Fatal(err)
	}
	seed(true)
	brandRaw, _ = os.ReadFile(filepath.Join(root, "config", "branding.xml"))
	brand = string(brandRaw)
	if strings.Contains(brand, "jellyfin.old.example.test") || !strings.Contains(brand, "https://jellyfin.example.test/sso/OID/start/authelia") {
		t.Fatalf("moved brand %s", brand)
	}

	old := "<BrandingOptions>\n  <LoginDisclaimer>old</LoginDisclaimer>\n  <CustomCss>.disclaimerContainer { display: block; }</CustomCss>\n</BrandingOptions>\n"
	if err := os.WriteFile(filepath.Join(root, "config", "branding.xml"), []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	seed(false)
	brandRaw, _ = os.ReadFile(filepath.Join(root, "config", "branding.xml"))
	brand = string(brandRaw)
	if strings.Contains(brand, "old") || !strings.Contains(brand, "sso/OID/start/authelia") || strings.Contains(brand, "paxSsoAt") {
		t.Fatalf("replaced brand %s", brand)
	}
	changed, err := jellyfinRemove(root)
	if err != nil || !changed {
		t.Fatalf("changed %v err %v", changed, err)
	}
	if _, err := os.Stat(filepath.Join(root, "plugins", "configurations", "SSO-Auth.xml")); !os.IsNotExist(err) {
		t.Fatal("sso xml still present")
	}
	brandRaw, _ = os.ReadFile(filepath.Join(root, "config", "branding.xml"))
	if strings.Contains(string(brandRaw), "sso/OID/start/authelia") {
		t.Fatalf("button remains %s", brandRaw)
	}
}
