package main

import (
	"fmt"
	"os"
	"strings"
)

func cmdResumeEnv(args []string) error {
	if err := needArgs("resume-env", args, 6); err != nil {
		return err
	}
	src, pgDst, appDst, appURL, oidcPath, discovery := args[0], args[1], args[2], args[3], args[4], args[5]
	pairs, err := parseEnvResume(src)
	if err != nil {
		return err
	}
	pairs = collapseEnv(pairs)
	env := map[string]string{}
	for _, pair := range pairs {
		env[pair.Key] = pair.Val
	}
	password := env["POSTGRES_PASSWORD"]
	if password == "" {
		return fmt.Errorf("resume env %s is missing POSTGRES_PASSWORD", src)
	}
	user := env["POSTGRES_USER"]
	if user == "" {
		user = "postgres"
	}
	database := env["POSTGRES_DB"]
	if database == "" {
		database = "postgres"
	}
	auth := env["AUTH_SECRET"]
	if len(auth) < 32 {
		return fmt.Errorf("resume env %s needs AUTH_SECRET of at least 32 characters (openssl rand -hex 32)", src)
	}
	if err := writeMode400(pgDst, []envPair{
		{"POSTGRES_USER", user},
		{"POSTGRES_PASSWORD", password},
		{"POSTGRES_DB", database},
	}); err != nil {
		return err
	}
	skip := map[string]bool{
		"POSTGRES_USER":     true,
		"POSTGRES_PASSWORD": true,
		"POSTGRES_DB":       true,
		"DATABASE_URL":      true,
		"APP_URL":           true,
		"PORT":              true,
		"NODE_ENV":          true,
		"TOKEN":             true,
	}
	var app []envPair
	for _, pair := range pairs {
		if skip[pair.Key] || strings.HasPrefix(pair.Key, "S3_") || strings.HasPrefix(pair.Key, "STORAGE_") {
			continue
		}
		app = append(app, pair)
	}
	app = append(app,
		envPair{"APP_URL", appURL},
		envPair{"DATABASE_URL", "postgresql://" + pyQuote(user) + ":" + pyQuote(password) + "@127.0.0.1:5432/" + pyQuote(database)},
		envPair{"PORT", "3000"},
		envPair{"NODE_ENV", "production"},
	)
	if oidcPath != "-" {
		raw, err := os.ReadFile(oidcPath)
		if err != nil {
			return err
		}
		secret := strings.TrimSpace(string(raw))
		if secret == "" {
			return fmt.Errorf("resume oidc secret is empty")
		}
		app = append(app,
			envPair{"OAUTH_PROVIDER_NAME", "Authelia"},
			envPair{"OAUTH_CLIENT_ID", "resume"},
			envPair{"OAUTH_CLIENT_SECRET", secret},
			envPair{"OAUTH_DISCOVERY_URL", discovery},

			envPair{"FLAG_DISABLE_EMAIL_AUTH", "true"},
		)
	}
	return writeMode400(appDst, app)
}

func collapseEnv(pairs []envPair) []envPair {
	index := map[string]int{}
	var out []envPair
	for _, pair := range pairs {
		if i, ok := index[pair.Key]; ok {
			out[i].Val = pair.Val
			continue
		}
		index[pair.Key] = len(out)
		out = append(out, pair)
	}
	return out
}

func writeMode400(path string, pairs []envPair) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o400)
	if err != nil {
		return err
	}
	for _, pair := range pairs {
		if _, err := fmt.Fprintf(f, "%s=%s\n", pair.Key, pair.Val); err != nil {
			f.Close()
			return err
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Chmod(path, 0o400)
}
