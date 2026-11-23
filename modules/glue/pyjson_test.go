package main

import (
	"bytes"
	"crypto/ecdh"
	"encoding/base64"
	"strings"
	"testing"
)

func TestPyJSONMatchesPythonSamples(t *testing.T) {
	affine := jObj(
		jkv("server", jObj(
			jkv("name", jStr("Example")),
			jkv("externalUrl", jStr("https://affine.example")),
		)),
		jkv("auth", jObj(
			jkv("allowSignup", jBool(false)),
			jkv("allowSignupForOauth", jBool(true)),
			jkv("requireEmailVerification", jBool(false)),
		)),
		jkv("oauth", jObj(
			jkv("providers", jObj(
				jkv("oidc", jObj(
					jkv("issuer", jStr("https://auth.example")),
					jkv("clientId", jStr("affine")),
					jkv("clientSecret", jStr("s'ecret")),
					jkv("allowPrivateNetwork", jBool(true)),
					jkv("args", jObj(
						jkv("scope", jStr("openid profile email")),
						jkv("claim_id", jStr("sub")),
						jkv("claim_email", jStr("email")),
						jkv("claim_name", jStr("name")),
					)),
				)),
			)),
		)),
		jkv("copilot", jObj(
			jkv("enabled", jBool(true)),
			jkv("byok", jObj(
				jkv("enabled", jBool(true)),
				jkv("allowCustomEndpoint", jBool(true)),
				jkv("allowPrivateEndpoint", jBool(true)),
			)),
		)),
	)
	wantAffine := `{"server": {"name": "Example", "externalUrl": "https://affine.example"}, "auth": {"allowSignup": false, "allowSignupForOauth": true, "requireEmailVerification": false}, "oauth": {"providers": {"oidc": {"issuer": "https://auth.example", "clientId": "affine", "clientSecret": "s'ecret", "allowPrivateNetwork": true, "args": {"scope": "openid profile email", "claim_id": "sub", "claim_email": "email", "claim_name": "name"}}}}, "copilot": {"enabled": true, "byok": {"enabled": true, "allowCustomEndpoint": true, "allowPrivateEndpoint": true}}}`
	if got := string(affine.Marshal(jSpaced)); got != wantAffine {
		t.Fatalf("affine\n%s", got)
	}
	indent := jObj(
		jkv("a", jNum("1")),
		jkv("b", jObj(
			jkv("c", jStr("x&y")),
			jkv("d", jArr(jStr("z"), jBool(true), jNull())),
		)),
	)
	wantIndent := "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"x&y\",\n    \"d\": [\n      \"z\",\n      true,\n      null\n    ]\n  }\n}"
	if got := string(indent.Marshal(jIndent)); got != wantIndent {
		t.Fatalf("indent\n%s", got)
	}
	unicode := jObj(jkv("s", jStr("héllo\n\t\"\\")))
	wantUnicode := `{"s":"h\u00e9llo\n\t\"\\"}`
	if got := string(unicode.Marshal(jCompact)); got != wantUnicode {
		t.Fatalf("unicode %s", got)
	}
}

func TestVAPIDUncompressedP256(t *testing.T) {
	pub, priv, err := vapidKeys()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(pub, "=") || strings.Contains(priv, "=") {
		t.Fatalf("padding pub %s priv %s", pub, priv)
	}
	rawPub, err := base64.RawURLEncoding.DecodeString(pub)
	if err != nil {
		t.Fatal(err)
	}
	rawPriv, err := base64.RawURLEncoding.DecodeString(priv)
	if err != nil {
		t.Fatal(err)
	}
	if len(rawPub) != 65 || rawPub[0] != 0x04 || len(rawPriv) != 32 {
		t.Fatalf("pub %d priv %d", len(rawPub), len(rawPriv))
	}
	key, err := ecdh.P256().NewPrivateKey(rawPriv)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(key.PublicKey().Bytes(), rawPub) {
		t.Fatal("public point does not match the scalar")
	}
}
