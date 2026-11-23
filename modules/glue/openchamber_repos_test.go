package main

import "testing"

func TestTokenForUsesTheActiveForgejoCredential(t *testing.T) {
	raw := []byte(`{"providers":{"forgejo":{"instances":{
		"https://other.example":{"activeCredentialId":"a","credentials":[{"credentialId":"a","token":"other"}]},
		"https://git.example":{"activeCredentialId":"keep","credentials":[
			{"credentialId":"old","status":"valid","token":"stale"},
			{"credentialId":"keep","status":"invalid","token":"nope"},
			{"credentialId":"keep","status":"valid","token":"placeholder-token"}
		]}
	}}}}`)
	token, ok, err := tokenFrom("git.example", raw)
	if err != nil || !ok || token != "placeholder-token" {
		t.Fatalf("%q %v %v", token, ok, err)
	}
	if _, ok, err := tokenFrom("missing.example", raw); err != nil || ok {
		t.Fatal("missing host")
	}
}
