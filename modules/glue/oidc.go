package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	reCustomCSS            = regexp.MustCompile(`(?s)<CustomCss>.*?</CustomCss>`)
	reDisclaimerThroughCSS = regexp.MustCompile(`(?s)\s*<LoginDisclaimer>.*?</CustomCss>`)
	reLoginDisclaimer      = regexp.MustCompile(`(?s)\s*<LoginDisclaimer>.*?</LoginDisclaimer>`)
	reDisclaimerCSS        = regexp.MustCompile(`(?s)\s*<CustomCss>.*?disclaimerContainer.*?</CustomCss>`)
)

func cmdJellyfinSeed(args []string) error {
	if len(args) != 8 && len(args) != 9 {
		return fmt.Errorf("jellyfin-seed: want VOL SECRET ISSUER CLIENT_ID PUBLIC_URL ROLES ADMIN_ROLES AUTO [EXTRA_CSS]")
	}
	extra := ""
	if len(args) == 9 {
		extra = args[8]
	}
	secret, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	return jellyfinSeed(args[0], strings.TrimSpace(string(secret)), args[2], args[3], args[4], args[5], args[6], args[7] == "1", extra)
}

func cmdJellyfinRemove(args []string) error {
	if err := needArgs("jellyfin-remove", args, 1); err != nil {
		return err
	}
	changed, err := jellyfinRemove(args[0])
	if err != nil {
		return err
	}
	if changed {
		fmt.Println("changed")
	}
	return nil
}

func xmlStrings(raw string) string {
	var b strings.Builder
	for _, part := range strings.Split(raw, ",") {
		if part == "" {
			continue
		}
		b.WriteString("<string>")
		b.WriteString(htmlEscape(part))
		b.WriteString("</string>")
	}
	return b.String()
}

func jellyfinInner(start string, auto bool) string {
	inner := `<form action="` + start + `">` +
		`<button class="raised block emby-button button-submit">Sign in with Authelia</button>` +
		`</form>`
	if auto {
		inner += `<img src="/web/assets/img/operator-sso.png" alt="" style="display:none" ` +
			`onerror="var t=sessionStorage.getItem('paxSsoAt');` +
			`if(!t||Date.now()-Number(t)>8000){sessionStorage.setItem('paxSsoAt',String(Date.now()));` +
			`location.replace('` + start + `')}">`
	}
	return inner
}

func reReplaceFirst(re *regexp.Regexp, s, repl string) (string, bool) {
	loc := re.FindStringIndex(s)
	if loc == nil {
		return s, false
	}
	return s[:loc[0]] + repl + s[loc[1]:], true
}

func jellyfinSeed(root, secret, issuer, clientID, publicURL, roles, adminRoles string, auto bool, extraCSS string) error {
	conf := filepath.Join(root, "plugins", "configurations")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		return err
	}

	old := filepath.Join(conf, "PluginConfiguration.xml")
	if err := os.Remove(old); err != nil && !os.IsNotExist(err) {
		return err
	}
	secret = htmlEscape(secret)
	xml := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
    <PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <SamlConfigs />
      <OidConfigs>
        <item>
          <key><string>authelia</string></key>
          <value>
            <PluginConfiguration>
              <OidEndpoint>%s</OidEndpoint>
              <OidClientId>%s</OidClientId>
              <OidSecret>%s</OidSecret>
              <Enabled>true</Enabled>
              <EnableAuthorization>true</EnableAuthorization>
              <EnableAllFolders>true</EnableAllFolders>
              <PreserveAdminPermissions>false</PreserveAdminPermissions>
              <AdminRoles>%s</AdminRoles>
              <Roles>%s</Roles>
              <RoleClaim>groups</RoleClaim>
              <OidScopes>
                <string>email</string>
                <string>groups</string>
              </OidScopes>
              <DefaultUsernameClaim>preferred_username</DefaultUsernameClaim>
              <DefaultProvider>Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider</DefaultProvider>
              <SchemeOverride>https</SchemeOverride>
              <DisablePushedAuthorization>true</DisablePushedAuthorization>
            </PluginConfiguration>
          </value>
        </item>
      </OidConfigs>
    </PluginConfiguration>
`, htmlEscape(issuer), htmlEscape(clientID), secret, xmlStrings(adminRoles), xmlStrings(roles))
	if err := os.WriteFile(filepath.Join(conf, "SSO-Auth.xml"), []byte(xml), 0o644); err != nil {
		return err
	}
	system := filepath.Join(root, "config", "system.xml")
	if isFile(system) {
		text, err := os.ReadFile(system)
		if err != nil {
			return err
		}
		updated := strings.ReplaceAll(string(text), "<QuickConnectAvailable>false</QuickConnectAvailable>", "<QuickConnectAvailable>true</QuickConnectAvailable>")
		if err := os.WriteFile(system, []byte(updated), 0o644); err != nil {
			return err
		}
	}
	brand := filepath.Join(root, "config", "branding.xml")
	if !isFile(brand) {
		return nil
	}
	raw, err := os.ReadFile(brand)
	if err != nil {
		return err
	}
	text := string(raw)
	start := publicURL + "/sso/OID/start/authelia"
	css := "a.raised.emby-button { padding: 0.9em 1em; color: inherit !important; } .disclaimerContainer { display: block; }"
	if strings.TrimSpace(extraCSS) != "" {
		css = css + " " + strings.TrimSpace(extraCSS)
	}
	button := "  <LoginDisclaimer>" + htmlEscape(jellyfinInner(start, auto)) + "</LoginDisclaimer>\n" +
		"      <CustomCss>" + css + "</CustomCss>\n    "

	disclaimerReady := strings.Contains(text, start) && (!auto || strings.Contains(text, "paxSsoAt"))
	cssReady := strings.Contains(text, "<CustomCss>"+css+"</CustomCss>")
	if disclaimerReady && cssReady {
		return nil
	}
	if disclaimerReady {
		updated, ok := reReplaceFirst(reCustomCSS, text, "<CustomCss>"+css+"</CustomCss>")
		if !ok || updated == text {
			updated = strings.ReplaceAll(text, "</BrandingOptions>", "      <CustomCss>"+css+"</CustomCss>\n</BrandingOptions>")
		}
		return os.WriteFile(brand, []byte(updated), 0o644)
	}
	if strings.Contains(text, "<LoginDisclaimer>") {
		updated, _ := reReplaceFirst(reDisclaimerThroughCSS, text, "\n"+rstrip(button))
		text = updated
	} else {
		text = strings.ReplaceAll(text, "</BrandingOptions>", button+"</BrandingOptions>")
	}
	return os.WriteFile(brand, []byte(text), 0o644)
}

func jellyfinRemove(root string) (bool, error) {
	changed := false
	plugins := filepath.Join(root, "plugins")
	if fi, err := os.Stat(plugins); err == nil && fi.IsDir() {
		matches, err := filepath.Glob(filepath.Join(plugins, "SSO-Auth_*"))
		if err != nil {
			return false, err
		}
		for _, path := range matches {
			info, err := os.Stat(path)
			if err != nil || !info.IsDir() {
				continue
			}
			if err := os.RemoveAll(path); err != nil {
				return false, err
			}
			changed = true
		}
		xml := filepath.Join(plugins, "configurations", "SSO-Auth.xml")
		if isFile(xml) {
			if err := os.Remove(xml); err != nil {
				return false, err
			}
			changed = true
		}
	}
	brand := filepath.Join(root, "config", "branding.xml")
	if isFile(brand) {
		raw, err := os.ReadFile(brand)
		if err != nil {
			return false, err
		}
		text := string(raw)
		if strings.Contains(text, "sso/OID/start/authelia") || strings.Contains(text, "paxSsoAt") {
			text, _ = reReplaceFirst(reLoginDisclaimer, text, "")
			text, _ = reReplaceFirst(reDisclaimerCSS, text, "")
			if err := os.WriteFile(brand, []byte(text), 0o644); err != nil {
				return false, err
			}
			changed = true
		}
	}
	return changed, nil
}
