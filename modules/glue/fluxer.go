package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

func tokenHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func tokenB64(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf), nil
}

func vapidKeys() (string, string, error) {
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	pub := key.PublicKey().Bytes()
	if len(pub) != 65 || pub[0] != 0x04 {
		return "", "", fmt.Errorf("vapid public key is not an uncompressed P-256 point")
	}
	priv := key.Bytes()
	if len(priv) != 32 {
		return "", "", fmt.Errorf("vapid private key is not 32 bytes")
	}
	return base64.RawURLEncoding.EncodeToString(pub), base64.RawURLEncoding.EncodeToString(priv), nil
}

func replaceLine(text, pattern, repl string) string {
	re := regexp.MustCompile(pattern)
	return re.ReplaceAllStringFunc(text, func(string) string { return repl })
}

func cmdFluxerEnv(args []string) error {
	if err := needArgs("fluxer-env", args, 1); err != nil {
		return err
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	text := string(raw)
	named := []string{
		"POSTGRES_PASSWORD",
		"MEILI_MASTER_KEY",
		"FLUXER_S3_SECRET_KEY",
		"FLUXER_SUDO_MODE_SECRET",
		"FLUXER_CONNECTION_INITIATION_SECRET",
		"FLUXER_GATEWAY_RPC_AUTH_TOKEN",
		"FLUXER_ERLANG_COOKIE",
		"FLUXER_MEDIA_PROXY_SECRET_KEY",
		"FLUXER_ADMIN_SECRET_KEY_BASE",
		"FLUXER_ADMIN_OAUTH_CLIENT_SECRET",
		"LIVEKIT_API_SECRET",
	}
	for _, key := range named {
		hexed, err := tokenHex(32)
		if err != nil {
			return err
		}
		text = replaceLine(text, `(?m)^`+regexp.QuoteMeta(key)+`=CHANGE_ME$`, key+"="+hexed)
	}
	relay, err := tokenB64(32)
	if err != nil {
		return err
	}
	text = replaceLine(text, `(?m)^FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=CHANGE_ME$`, "FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64="+relay)
	pub, priv, err := vapidKeys()
	if err != nil {
		return err
	}
	text = replaceLine(text, `(?m)^FLUXER_VAPID_PUBLIC_KEY=CHANGE_ME$`, "FLUXER_VAPID_PUBLIC_KEY="+pub)
	text = replaceLine(text, `(?m)^FLUXER_VAPID_PRIVATE_KEY=CHANGE_ME$`, "FLUXER_VAPID_PRIVATE_KEY="+priv)
	if strings.Contains(text, "=CHANGE_ME") {
		return fmt.Errorf("unfilled CHANGE_ME values remain in Fluxer .env")
	}
	return os.WriteFile(args[0], []byte(text), 0o600)
}

const livekitStun = "          stun_servers:\n" +
	"            - ${FLUXER_LIVEKIT_STUN_PRIMARY:-stun.l.google.com:19302}\n" +
	"            - ${FLUXER_LIVEKIT_STUN_SECONDARY:-stun1.l.google.com:19302}\n"

const livekitTurn = livekitStun + "          turn_servers:\n" +
	"            - host: ${FLUXER_LIVEKIT_TURN_HOST}\n" +
	"              port: 3478\n" +
	"              protocol: tcp\n" +
	"              secret: ${FLUXER_LIVEKIT_TURN_SECRET}\n" +
	"            - host: ${FLUXER_LIVEKIT_TURN_HOST}\n" +
	"              port: 3478\n" +
	"              protocol: udp\n" +
	"              secret: ${FLUXER_LIVEKIT_TURN_SECRET}\n"

func cmdFluxerTurn(args []string) error {
	if err := needArgs("fluxer-turn", args, 3); err != nil {
		return err
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	text := string(raw)
	host := args[2]
	if !regexp.MustCompile(`(?m)^FLUXER_LIVEKIT_TURN_SECRET=`).MatchString(text) {
		secret, err := tokenHex(32)
		if err != nil {
			return err
		}
		text += "\nFLUXER_LIVEKIT_TURN_SECRET=" + secret + "\n"
	}
	if regexp.MustCompile(`(?m)^FLUXER_LIVEKIT_TURN_HOST=`).MatchString(text) {
		text = replaceLine(text, `(?m)^FLUXER_LIVEKIT_TURN_HOST=.*$`, "FLUXER_LIVEKIT_TURN_HOST="+host)
	} else {
		text += "\nFLUXER_LIVEKIT_TURN_HOST=" + host + "\n"
	}
	composeRe := regexp.MustCompile(`(?m)^COMPOSE_FILE=.*$`)
	if composeRe.MatchString(text) {
		text = composeRe.ReplaceAllStringFunc(text, func(line string) string {
			if strings.Contains(line, "docker-compose.turn.yml") {
				return line
			}
			return line + ":docker-compose.turn.yml"
		})
	} else {
		text += "COMPOSE_FILE=docker-compose.yml:docker-compose.proxy.yml:docker-compose.turn.yml\n"
	}
	if err := os.WriteFile(args[0], []byte(text), 0o600); err != nil {
		return err
	}
	composeRaw, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	compose := string(composeRaw)
	if strings.Contains(compose, "turn_servers:") {
		return nil
	}
	if !strings.Contains(compose, livekitStun) {
		return fmt.Errorf("could not patch LiveKit turn_servers into docker-compose.yml")
	}
	compose = strings.Replace(compose, livekitStun, livekitTurn, 1)
	return os.WriteFile(args[1], []byte(compose), 0o644)
}

func fluxerNow() string {
	t := time.Now().UTC()
	ms := t.Nanosecond() / 1e6
	return t.Format("2006-01-02T15:04:05") + fmt.Sprintf(".%03dZ", ms)
}

func redact(text, secret string) string {
	if secret == "" {
		return text
	}
	return strings.ReplaceAll(text, secret, "[redacted]")
}

func fluxerPsql(input string, args ...string) (string, string, int, error) {
	cmdArgs := append([]string{
		"exec", "-i", "fluxer-postgres-1", "psql",
		"-U", "fluxer", "-d", "fluxer",
		"-v", "ON_ERROR_STOP=1", "-At",
	}, args...)
	cmd := exec.Command("docker", cmdArgs...)
	cmd.Stdin = strings.NewReader(input)
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return stdout.String(), stderr.String(), 0, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return stdout.String(), stderr.String(), exit.ExitCode(), nil
	}
	return "", err.Error(), -1, err
}

func waitFluxerPostgres() error {
	for i := 0; i < 30; i++ {
		cmd := exec.Command("docker", "exec", "fluxer-postgres-1", "pg_isready", "-U", "fluxer", "-d", "fluxer")
		cmd.Stdout = io.Discard
		cmd.Stderr = io.Discard
		if cmd.Run() == nil {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("fluxer postgres is not ready")
}

const boardAccent = "@accent@"

func jField(v *JVal, key string) (string, bool) {
	if v == nil || v.Kind != kindObj {
		return "", false
	}
	for _, pair := range v.Obj {
		if pair.Key == key && pair.Val.Kind == kindStr {
			return pair.Val.Str, true
		}
	}
	return "", false
}

func fluxerBoardTheme(value string) (string, bool, error) {
	if strings.TrimSpace(value) == "" {
		return value, false, nil
	}
	doc, err := parseJSON(value)
	if err != nil {
		return "", false, err
	}
	branding, err := doc.setDefaultObj("branding")
	if err != nil {
		return "", false, err
	}
	if cur, ok := jField(branding, "theme_color"); ok && cur == boardAccent {
		return value, false, nil
	}
	branding.Set("theme_color", jStr(boardAccent))
	return string(doc.Marshal(jCompact)), true, nil
}

func applyFluxerBoardTheme() (bool, error) {
	stdout, stderr, code, err := fluxerPsql("",
		"-c", "SELECT coalesce(row_data->>'value', '') FROM fluxer_kv "+
			"WHERE table_name = 'instance_configuration' AND row_key = '\"app_public_config\"'",
	)
	if err != nil {
		return false, err
	}
	if code != 0 {
		return false, errors.New(strings.TrimSpace(stderr))
	}
	next, changed, err := fluxerBoardTheme(strings.TrimSpace(stdout))
	if err != nil || !changed {
		return false, err
	}
	if strings.Contains(next, "$boardtheme$") {
		return false, fmt.Errorf("fluxer branding collided with the sql delimiter")
	}
	sql := "UPDATE fluxer_kv SET row_data = jsonb_set(row_data, '{value}', to_jsonb($boardtheme$" + next + "$boardtheme$::text)), updated_at = now() " +
		"WHERE table_name = 'instance_configuration' AND row_key = '\"app_public_config\"';\n"
	_, stderr, code, err = fluxerPsql(sql)
	if err != nil {
		return false, err
	}
	if code != 0 {
		return false, errors.New(strings.TrimSpace(stderr))
	}
	return true, nil
}

func cmdFluxerSSO(args []string) error {
	if err := needArgs("fluxer-sso", args, 3); err != nil {
		return err
	}
	secretRaw, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	secret := strings.TrimSpace(string(secretRaw))
	if secret == "" {
		return fmt.Errorf("fluxer oidc secret is empty")
	}
	dataDir := args[1]
	issuer := strings.TrimRight(args[2], "/")
	now := fluxerNow()
	values := []struct{ key, val string }{
		{"sso_enabled", "true"},
		{"sso_enforced", "false"},
		{"sso_display_name", "Authelia"},
		{"sso_issuer", issuer},
		{"sso_authorization_url", issuer + "/api/oidc/authorization"},
		{"sso_token_url", issuer + "/api/oidc/token"},
		{"sso_userinfo_url", issuer + "/api/oidc/userinfo"},
		{"sso_jwks_url", issuer + "/jwks.json"},
		{"sso_client_id", "fluxer"},
		{"sso_client_secret", secret},
		{"sso_scope", "openid email profile"},
		{"sso_allowed_domains", "[\"app.example.com\"]"},
		{"sso_auto_provision", "true"},
		{"sso_redirect_uri", ""},
	}
	if err := waitFluxerPostgres(); err != nil {
		return err
	}
	stdout, stderr, code, err := fluxerPsql("",
		"-F", "\t",
		"-c", "SELECT row_key, coalesce(row_data->>'value', '') FROM fluxer_kv "+
			"WHERE table_name = 'instance_configuration' AND row_key LIKE '\"sso_%'",
	)
	if err != nil {
		return err
	}
	if code != 0 {
		return errors.New(redact(stderr, secret))
	}
	have := map[string]string{}
	for _, line := range splitLines(stdout) {
		if !strings.Contains(line, "\t") {
			continue
		}
		key, value, _ := strings.Cut(line, "\t")
		have[key] = value
	}
	same := true
	for _, item := range values {
		if have[string(appendPyString(nil, item.key))] != item.val {
			same = false
			break
		}
	}
	themeChanged, err := applyFluxerBoardTheme()
	if err != nil {
		return err
	}
	if same && !themeChanged {
		fmt.Println("fluxer-sso-unchanged")
		return nil
	}
	if !same {
		statements := []string{"BEGIN;"}
		for _, item := range values {
			quoted := string(appendPyString(nil, item.key))
			row := jObj(
				jkv("key", jStr(item.key)),
				jkv("value", jStr(item.val)),
				jkv("updated_at", jObj(
					jkv("value", jStr(now)),
					jkv("__fluxer_type", jStr("date")),
				)),
			)
			payload := string(row.Marshal(jCompact))
			if strings.Contains(quoted, "$sso$") || strings.Contains(payload, "$sso$") {
				return fmt.Errorf("fluxer sso row collided with the sql delimiter")
			}
			statements = append(statements,
				"INSERT INTO fluxer_kv (table_name, partition_key, row_key, row_data) "+
					"VALUES ('instance_configuration', $sso$"+quoted+"$sso$, $sso$"+quoted+"$sso$, "+
					"$sso$"+payload+"$sso$::jsonb) "+
					"ON CONFLICT (table_name, row_key) DO UPDATE "+
					"SET row_data = EXCLUDED.row_data, updated_at = now();",
			)
		}
		statements = append(statements, "COMMIT;")
		_, stderr, code, err = fluxerPsql(strings.Join(statements, "\n") + "\n")
		if err != nil {
			return err
		}
		if code != 0 {
			return errors.New(redact(stderr, secret))
		}
	}
	cmd := exec.Command("docker", "compose", "restart", "api")
	cmd.Dir = dataDir
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		detail := errBuf.String()
		if detail == "" {
			detail = outBuf.String()
		}
		detail = redact(detail, secret)
		if strings.TrimSpace(detail) == "" {
			detail = "docker compose restart api failed"
		}
		return errors.New(detail)
	}
	if !same {
		fmt.Println("fluxer-sso-updated")
	}
	if themeChanged {
		fmt.Println("fluxer-theme-updated")
	}
	return nil
}
