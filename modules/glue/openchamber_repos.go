package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	workspaceRoot = "/home/openchamber/workspaces"
	authFile      = "/run/job-cred/source-control-auth.json"
	chamberOrigin = "http://127.0.0.1:3000"
	ocbiConfig    = "/home/openchamber/.config/opencode/codebase-index.json"
	ocbiJS        = "/opt/ocbi/node_modules/open-codebase-index/dist/cbi.js"
)

type runMode int

const (
	modeCapture runMode = iota
	modeBoth
	modeQuiet
	modeInherit
)

type procResult struct {
	stdout string
	code   int
	failed bool
}

type statusError struct{ code int }

func (e *statusError) Error() string { return strconv.Itoa(e.code) }

type repoRecord struct {
	owner   string
	name    string
	branch  string
	archive bool
}

type presentRepo struct {
	label    string
	dest     string
	archived bool
	owner    string
	name     string
}

type syncer struct {
	origin      string
	token       string
	root        string
	authPath    string
	env         []string
	forgeClient *http.Client
	headClient  *http.Client
	chamber     *http.Client
	now         func() int64
	runner      func(argv []string, timeout time.Duration, mode runMode) procResult
	logf        func(args ...any)
	apiFn       func(path string) (any, error)
	callFn      func(method, path string, body any) (any, error)
}

func cmdOpenChamberRepos(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("openchamber-repos: want origin and orgs")
	}
	origin := strings.TrimRight(args[0], "/")
	orgs := args[1:]
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Hostname() == "" {
		host := ""
		if parsed != nil {
			host = parsed.Hostname()
		}
		return fmt.Errorf("openchamber-repos: no Forgejo credential for %s", host)
	}
	token, err := tokenFor(parsed.Hostname(), authFile)
	if err != nil {
		return err
	}
	if token == "" {
		return fmt.Errorf("openchamber-repos: no Forgejo credential for %s", parsed.Hostname())
	}
	s := newSyncer(origin, token)
	present, failed, err := s.checkout(orgs)
	if err != nil {
		return err
	}
	if len(present) > 0 {
		if err := s.register(present); err != nil {
			return err
		}
	}
	if failed {
		os.Exit(1)
	}
	return nil
}

func newSyncer(origin, token string) *syncer {
	env := os.Environ()
	env = setEnv(env, "GIT_LFS_SKIP_SMUDGE", "1")
	env = setEnv(env, "GIT_TERMINAL_PROMPT", "0")
	s := &syncer{
		origin:      origin,
		token:       token,
		root:        workspaceRoot,
		authPath:    authFile,
		env:         env,
		forgeClient: &http.Client{Timeout: 60 * time.Second},
		headClient:  &http.Client{Timeout: 20 * time.Second},
		now:         func() int64 { return time.Now().UnixMilli() },
		logf:        func(args ...any) { fmt.Println(args...) },
	}
	s.runner = s.exec
	return s
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	next := make([]string, 0, len(env)+1)
	for _, item := range env {
		if !strings.HasPrefix(item, prefix) {
			next = append(next, item)
		}
	}
	return append(next, prefix+value)
}

func (s *syncer) log(args ...any) {
	s.logf(args...)
}

func (s *syncer) exec(argv []string, timeout time.Duration, mode runMode) procResult {
	ctx := context.Background()
	cancel := func() {}
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(context.Background(), timeout)
	}
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = s.env
	var stdout bytes.Buffer
	switch mode {
	case modeBoth:
		cmd.Stdout = &stdout
		cmd.Stderr = &stdout
	case modeQuiet:
		cmd.Stdout = &stdout
		cmd.Stderr = io.Discard
	case modeInherit:
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	default:
		cmd.Stdout = &stdout
		cmd.Stderr = os.Stderr
	}
	err := cmd.Run()
	if timeout > 0 && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return procResult{failed: true}
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return procResult{stdout: stdout.String(), code: exit.ExitCode()}
		}
		return procResult{stdout: stdout.String(), failed: true}
	}
	return procResult{stdout: stdout.String(), code: 0}
}

func tokenFor(host, path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("openchamber-repos: credential file is unreadable")
	}
	token, ok, err := tokenFrom(host, raw)
	if err != nil {
		return "", fmt.Errorf("openchamber-repos: credential file is unreadable")
	}
	if !ok {
		return "", nil
	}
	return token, nil
}

func tokenFrom(host string, raw []byte) (string, bool, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return "", false, err
	}
	providers, _ := objectOf(root["providers"])
	forgejo, _ := objectOf(providers["forgejo"])
	instances, keys, err := orderedObject(forgejo["instances"])
	if err != nil {
		return "", false, err
	}
	for _, key := range keys {
		parsed, err := url.Parse(key)
		if err != nil || parsed.Hostname() != host {
			continue
		}
		inst, _ := objectOf(instances[key])
		var wanted string
		if rawID, ok := inst["activeCredentialId"]; ok {
			_ = json.Unmarshal(rawID, &wanted)
		}
		var creds []json.RawMessage
		if rawCreds, ok := inst["credentials"]; ok && string(rawCreds) != "null" {
			if err := json.Unmarshal(rawCreds, &creds); err != nil {
				continue
			}
		}
		for _, rawCred := range creds {
			cred, _ := objectOf(rawCred)
			var id string
			if rawID, ok := cred["credentialId"]; ok {
				_ = json.Unmarshal(rawID, &id)
			}
			if id != wanted {
				continue
			}
			if !credentialUsable(cred["status"]) {
				continue
			}
			var token string
			if rawToken, ok := cred["token"]; ok {
				_ = json.Unmarshal(rawToken, &token)
			}
			return token, true, nil
		}
	}
	return "", false, nil
}

func credentialUsable(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return true
	}
	var status string
	if err := json.Unmarshal(raw, &status); err != nil {
		return false
	}
	return status == "" || status == "valid"
}

func objectOf(raw json.RawMessage) (map[string]json.RawMessage, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return map[string]json.RawMessage{}, nil
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}
	if obj == nil {
		obj = map[string]json.RawMessage{}
	}
	return obj, nil
}

func orderedObject(raw json.RawMessage) (map[string]json.RawMessage, []string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return map[string]json.RawMessage{}, nil, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		return nil, nil, err
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return nil, nil, fmt.Errorf("object")
	}
	vals := map[string]json.RawMessage{}
	var keys []string
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return nil, nil, err
		}
		key, ok := tok.(string)
		if !ok {
			return nil, nil, fmt.Errorf("key")
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, nil, err
		}
		if _, seen := vals[key]; !seen {
			keys = append(keys, key)
		}
		vals[key] = value
	}
	return vals, keys, nil
}

func decodeJSON(raw []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, err
	}
	return value, nil
}

func marshalJSON(value any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func (s *syncer) api(path string) (any, error) {
	if s.apiFn != nil {
		return s.apiFn(path)
	}
	req, err := http.NewRequest(http.MethodGet, s.origin+"/api/v1"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "token "+s.token)
	resp, err := s.forgeClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &statusError{code: resp.StatusCode}
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, nil
	}
	return decodeJSON(raw)
}

func (s *syncer) checkout(orgs []string) ([]presentRepo, bool, error) {
	for _, org := range orgs {
		if !nameOK(org) {
			return nil, false, fmt.Errorf("openchamber-repos: bad org name")
		}
	}
	repos, err := s.listRepos(orgs)
	if err != nil {
		return nil, false, err
	}
	s.log("repos", len(repos))
	var present []presentRepo
	failed := false
	for _, repo := range repos {
		item, repoFailed, fatal := s.syncRepo(repo)
		if fatal != nil {
			return nil, false, fatal
		}
		if repoFailed {
			failed = true
		}
		if item.dest != "" {
			present = append(present, item)
		}
	}
	return present, failed, nil
}

func (s *syncer) listRepos(orgs []string) ([]repoRecord, error) {
	wanted := map[string]bool{}
	for _, org := range orgs {
		wanted[org] = true
	}
	var repos []repoRecord
	for page := 1; ; page++ {
		batch, err := s.api("/user/repos?limit=50&page=" + strconv.Itoa(page))
		if err != nil {
			var status *statusError
			if errors.As(err, &status) {
				return nil, fmt.Errorf("openchamber-repos: repo list failed %d", status.code)
			}
			return nil, fmt.Errorf("openchamber-repos: repo list failed")
		}
		list, ok := asList(batch)
		if !ok {
			if batch == nil {
				break
			}
			return nil, fmt.Errorf("openchamber-repos: repo list failed")
		}
		if len(list) == 0 {
			break
		}
		for _, item := range list {
			repo, ok := asMap(item)
			if !ok {
				continue
			}
			owner := nestedString(repo, "owner", "login")
			if !wanted[owner] {
				continue
			}
			branch := asString(repo["default_branch"])
			if branch == "" {
				branch = "main"
			}
			repos = append(repos, repoRecord{
				owner:   owner,
				name:    asString(repo["name"]),
				branch:  branch,
				archive: jsonBool(repo["archived"]),
			})
		}
		if len(list) < 50 {
			break
		}
	}
	return repos, nil
}

func (s *syncer) failRepo(owner, name, dest string) (presentRepo, bool, error) {
	s.log("failed", owner+"/"+name)
	if dest != "" {
		_ = s.ignoreIndex(dest)
	}
	return presentRepo{}, true, nil
}

func (s *syncer) syncRepo(repo repoRecord) (presentRepo, bool, error) {
	owner, name, branch := repo.owner, repo.name, repo.branch
	if !nameOK(owner) || !nameOK(name) || !refOK(branch) {
		s.log("skip bad name", owner, name)
		return presentRepo{}, true, nil
	}
	dest := filepath.Join(s.root, owner, name)
	if !pathInside(s.root, dest) {
		s.log("skip", owner+"/"+name)
		return presentRepo{}, true, nil
	}

	if repo.archive && !isDir(filepath.Join(dest, ".git")) {
		s.log("archived", owner+"/"+name)
		return presentRepo{}, false, nil
	}
	clone := s.origin + "/" + owner + "/" + name + ".git"
	moved := false
	if err := s.claimRenamed(dest, clone); err != nil {
		return s.failRepo(owner, name, dest)
	}
	gitDir := filepath.Join(dest, ".git")
	if !isDir(gitDir) {
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return s.failRepo(owner, name, "")
		}
		if err := s.gitCall("clone", "--origin", "origin", clone, dest); err != nil {
			return s.failRepo(owner, name, dest)
		}
		s.log("cloned", owner+"/"+name)
	} else {
		if err := s.gitCall("-C", dest, "fetch", "--prune", "origin"); err != nil {
			return s.failRepo(owner, name, dest)
		}
		dirty, err := s.gitText("-C", dest, "status", "--porcelain")
		if err != nil {
			return s.failRepo(owner, name, dest)
		}
		head, err := s.gitText("-C", dest, "rev-parse", "--abbrev-ref", "HEAD")
		if err != nil {
			return s.failRepo(owner, name, dest)
		}
		ahead, err := s.gitText("-C", dest, "rev-list", "--count", "origin/"+branch+"..HEAD")
		if err != nil {
			return s.failRepo(owner, name, dest)
		}
		behind, err := s.gitText("-C", dest, "rev-list", "--count", "HEAD..origin/"+branch)
		if err != nil {
			return s.failRepo(owner, name, dest)
		}
		if strings.TrimSpace(dirty) != "" || strings.TrimSpace(head) != branch || strings.TrimSpace(ahead) != "0" {
			s.log("fetched", owner+"/"+name)
		} else if strings.TrimSpace(behind) != "0" {
			if err := s.gitCall("-C", dest, "merge", "--ff-only", "origin/"+branch); err != nil {
				return s.failRepo(owner, name, dest)
			}
			s.log("updated", owner+"/"+name)
			moved = true
		}
	}
	if err := s.ignoreIndex(dest); err != nil {
		return presentRepo{}, false, err
	}
	if !repo.archive {
		due, err := s.indexDue(dest, moved)
		if err != nil {
			return presentRepo{}, false, err
		}
		if due {
			indexed, indexFailed, fatal := s.refreshIndex(dest)
			if fatal != nil {
				return presentRepo{}, false, fatal
			}
			if indexed {
				s.log("indexed", owner+"/"+name)
			} else if indexFailed {
				s.log("index failed", owner+"/"+name)
				resolved, err := resolveExisting(dest)
				if err != nil {
					return presentRepo{}, false, err
				}
				return presentRepo{
					label: owner + "/" + name, dest: resolved, archived: repo.archive,
					owner: owner, name: name,
				}, true, nil
			}
		}
	}
	resolved, err := resolveExisting(dest)
	if err != nil {
		return presentRepo{}, false, err
	}
	return presentRepo{
		label: owner + "/" + name, dest: resolved, archived: repo.archive,
		owner: owner, name: name,
	}, false, nil
}

func pathInside(root, dest string) bool {
	rel, err := filepath.Rel(root, dest)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	return !filepath.IsAbs(rel)
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func resolveExisting(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

func (s *syncer) gitCall(args ...string) error {
	proc := s.runner(append([]string{"git"}, args...), 0, modeInherit)
	if proc.failed || proc.code != 0 {
		return fmt.Errorf("git")
	}
	return nil
}

func (s *syncer) gitText(args ...string) (string, error) {
	proc := s.runner(append([]string{"git"}, args...), 0, modeCapture)
	if proc.failed || proc.code != 0 {
		return "", fmt.Errorf("git")
	}
	return proc.stdout, nil
}

func (s *syncer) gitQuiet(args ...string) (string, error) {
	proc := s.runner(append([]string{"git"}, args...), 0, modeQuiet)
	if proc.failed || proc.code != 0 {
		return "", fmt.Errorf("git")
	}
	return proc.stdout, nil
}

func (s *syncer) ignoreIndex(dest string) error {
	git := filepath.Join(dest, ".git")
	if !isDir(git) {
		return nil
	}
	exclude := filepath.Join(git, "info", "exclude")
	if err := os.MkdirAll(filepath.Dir(exclude), 0o755); err != nil {
		return err
	}
	current := ""
	if raw, err := os.ReadFile(exclude); err == nil {
		current = string(raw)
	}
	for _, line := range splitLines(current) {
		if line == ".opencode/" {
			return nil
		}
	}
	var next string
	if current != "" && !strings.HasSuffix(current, "\n") {
		next = "\n"
	}
	next += ".opencode/\n"
	f, err := os.OpenFile(exclude, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(next)
	return err
}

func (s *syncer) claimRenamed(dest, clone string) error {
	if isDir(filepath.Join(dest, ".git")) {
		current, err := s.gitText("-C", dest, "remote", "get-url", "origin")
		if err != nil {
			return err
		}
		if strings.TrimSpace(current) != clone {
			return s.gitCall("-C", dest, "remote", "set-url", "origin", clone)
		}
		return nil
	}
	parent := filepath.Dir(dest)
	if !isDir(parent) {
		return nil
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		return err
	}
	base := filepath.Base(dest)
	for _, entry := range entries {
		if entry.Name() == base || !isDir(filepath.Join(parent, entry.Name(), ".git")) {
			continue
		}
		sibling := filepath.Join(parent, entry.Name())
		raw, err := s.gitText("-C", sibling, "remote", "get-url", "origin")
		if err != nil {
			continue
		}
		if !s.sameRepo(strings.TrimSpace(raw), clone) {
			continue
		}
		if err := os.Rename(sibling, dest); err != nil {
			return err
		}
		if err := s.gitCall("-C", dest, "remote", "set-url", "origin", clone); err != nil {
			return err
		}
		s.log("renamed", entry.Name(), "->", base)
		return nil
	}
	return nil
}

func normRepo(value string) string {
	return strings.TrimSuffix(strings.TrimRight(value, "/"), ".git")
}

func (s *syncer) sameRepo(remote, clone string) bool {
	if normRepo(remote) == normRepo(clone) {
		return true
	}
	req, err := http.NewRequest(http.MethodHead, remote, nil)
	if err != nil {
		return false
	}
	resp, err := s.headClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false
	}
	final := remote
	if resp.Request != nil && resp.Request.URL != nil {
		final = resp.Request.URL.String()
	}
	return normRepo(final) == normRepo(clone)
}

func (s *syncer) ocbi(dest, command string) (procResult, bool, error) {
	if !isFile(ocbiConfig) {
		return procResult{}, false, nil
	}
	proc := s.runner([]string{
		"node", ocbiJS, command,
		"--project", dest,
		"--config", ocbiConfig,
		"--host", "opencode",
	}, 0, modeBoth)
	if proc.failed {
		return proc, true, fmt.Errorf("openchamber-repos: index command failed")
	}
	return proc, true, nil
}

func (s *syncer) indexDue(dest string, moved bool) (bool, error) {
	index := filepath.Join(dest, ".opencode", "index")
	failedBatch := false
	if isDir(index) {
		matches, err := filepath.Glob(filepath.Join(index, "failed-batches*.json"))
		if err != nil {
			return false, err
		}
		failedBatch = len(matches) > 0
	}
	due := moved || failedBatch || !isFile(filepath.Join(index, "codebase.db"))
	if !due {
		pending, err := s.migrationPending(dest)
		if err != nil {
			return false, err
		}
		due = pending
	}
	return due, nil
}

func (s *syncer) migrationPending(dest string) (bool, error) {
	proc, ran, err := s.ocbi(dest, "status")
	if err != nil || !ran {
		return false, err
	}
	for _, line := range splitLines(proc.stdout) {
		if strings.TrimSpace(line) == "Storage migrations: pending" {
			return true, nil
		}
	}
	return false, nil
}

func (s *syncer) refreshIndex(dest string) (indexed bool, failed bool, fatal error) {
	proc, ran, err := s.ocbi(dest, "index")
	if err != nil {
		return false, false, err
	}
	if !ran {
		return false, false, nil
	}
	if proc.code != 0 {
		return false, true, nil
	}
	return true, false, nil
}

func (s *syncer) register(present []presentRepo) error {
	password := os.Getenv("OPENCHAMBER_UI_PASSWORD")
	if password == "" {
		return fmt.Errorf("openchamber-repos: UI password is not set")
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return err
	}
	s.chamber = &http.Client{Timeout: 60 * time.Second, Jar: jar}
	if _, err := s.call("POST", "/auth/session", map[string]any{"password": password}); err != nil {
		return err
	}
	return s.syncProjects(present)
}

func (s *syncer) call(method, path string, body any) (any, error) {
	if s.callFn != nil {
		return s.callFn(method, path, body)
	}
	code, payload, empty, err := s.chamberDo(method, path, body)
	if err != nil {
		return nil, fmt.Errorf("openchamber-repos: %s %s failed", method, path)
	}
	if code < 200 || code >= 300 {
		return nil, fmt.Errorf("openchamber-repos: %s %s failed %d", method, path, code)
	}
	if empty {
		return map[string]any{}, nil
	}
	return payload, nil
}

func (s *syncer) chamberDo(method, path string, body any) (int, any, bool, error) {
	var reader io.Reader
	if body != nil {
		raw, err := marshalJSON(body)
		if err != nil {
			return 0, nil, false, err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, chamberOrigin+path, reader)
	if err != nil {
		return 0, nil, false, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := s.chamber.Do(req)
	if err != nil {
		return 0, nil, false, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, false, err
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return resp.StatusCode, nil, true, nil
	}
	value, err := decodeJSON(raw)
	if err != nil {
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp.StatusCode, nil, false, err
		}
		return resp.StatusCode, nil, false, nil
	}
	return resp.StatusCode, value, false, nil
}

func (s *syncer) syncProjects(present []presentRepo) error {
	settings, err := s.call(http.MethodGet, "/api/config/settings", nil)
	if err != nil {
		return err
	}
	doc, ok := asMap(settings)
	if !ok {
		return fmt.Errorf("openchamber-repos: project list is malformed")
	}
	projects, ok := asList(doc["projects"])
	if !ok && doc["projects"] != nil {
		return fmt.Errorf("openchamber-repos: project list is malformed")
	}
	if projects == nil {
		projects = []any{}
	}
	live := map[string]bool{}
	for _, repo := range present {
		live[repo.dest] = true
	}
	kept := make([]any, 0, len(projects))
	dropped := 0
	rootPrefix := s.root + "/"
	for _, entry := range projects {
		row, ok := asMap(entry)
		path := ""
		if ok {
			path = asString(row["path"])
		}
		if path != "" && strings.HasPrefix(path, rootPrefix) && !live[path] {
			dropped++
			continue
		}
		kept = append(kept, entry)
	}
	if dropped > 0 {
		projects = kept
		s.log("dropped", dropped)
	}
	known := map[string]bool{}
	for _, entry := range projects {
		row, ok := asMap(entry)
		if !ok {
			continue
		}
		if path := asString(row["path"]); path != "" {
			known[path] = true
		}
	}
	added := 0
	now := s.now()
	for _, repo := range present {
		if known[repo.dest] {
			continue
		}
		projects = append(projects, map[string]any{
			"id":          projectID(repo.dest),
			"path":        repo.dest,
			"label":       repo.label,
			"labelSource": "auto",
			"addedAt":     now,
		})
		added++
	}
	if added > 0 || dropped > 0 {
		if _, err := s.call(http.MethodPut, "/api/config/settings", map[string]any{"projects": projects}); err != nil {
			return err
		}
		s.log("registered", added)
	}
	return nil
}

func nameOK(value string) bool {
	if strings.Contains(value, "..") || strings.Contains(value, "/") || utf8.RuneCountInString(value) > 100 {
		return false
	}
	stripped := strings.NewReplacer(".", "", "-", "", "_", "").Replace(value)
	if stripped == "" {
		return false
	}
	for _, r := range stripped {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func refOK(value string) bool {
	if value == "" || strings.Contains(value, "..") || strings.Contains(value, "\n") || strings.HasPrefix(value, "-") {
		return false
	}
	if strings.HasPrefix(value, "/") || utf8.RuneCountInString(value) > 200 {
		return false
	}
	return true
}

func projectID(path string) string {
	return "path_" + base64.RawURLEncoding.EncodeToString([]byte(path))
}

func asMap(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

func asList(v any) ([]any, bool) {
	list, ok := v.([]any)
	return list, ok
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}

func jsonBool(v any) bool {
	b, ok := v.(bool)
	return ok && b
}

func nestedString(m map[string]any, keys ...string) string {
	var cur any = m
	for _, key := range keys {
		obj, ok := asMap(cur)
		if !ok {
			return ""
		}
		cur = obj[key]
	}
	return asString(cur)
}
