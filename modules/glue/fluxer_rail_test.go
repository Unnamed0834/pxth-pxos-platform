package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRailDiscoveryUsesPublishedEndpoints(t *testing.T) {
	body := []byte(`{"endpoints":{"api_public":"https://fluxer.example/api","gateway":"wss://fluxer.example/gateway","media":"https://fluxer.example/media"}}`)
	disc, err := parseDiscovery(body)
	if err != nil {
		t.Fatal(err)
	}
	if disc.API != "https://fluxer.example/api" || disc.Gateway != "wss://fluxer.example/gateway" || disc.Media != "https://fluxer.example/media" {
		t.Fatalf("discovery %+v", disc)
	}
	if _, err := parseDiscovery([]byte(`{"endpoints":{"api":"https://fluxer.example/api"}}`)); err == nil {
		t.Fatal("incomplete discovery was accepted")
	}
}

func TestRailGatewayQuery(t *testing.T) {
	got, err := withGatewayQuery("wss://fluxer.example/gateway?compress=zstd-stream&stream=1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "v=1") || !strings.Contains(got, "encoding=json") || strings.Contains(got, "compress") || strings.Contains(got, "stream") {
		t.Fatalf("gateway url %s", got)
	}
}

func TestRailPickGeneral(t *testing.T) {
	channels := []fxChannel{
		{ID: "cat", Type: 4, Name: "general"},
		{ID: "ann", Type: 5, Name: "General"},
		{ID: "text", Type: 0, Name: "general"},
	}
	id, ok := pickGeneral(channels, "general")
	if !ok || id != "text" {
		t.Fatalf("picked %s %v", id, ok)
	}
}

func TestRailClip(t *testing.T) {
	if clipText("  hello\nthere  ", 0) != "hello there" {
		t.Fatalf("clip %q", clipText("  hello\nthere  ", 0))
	}
	long := strings.Repeat("a", 200)
	clipped := clipText(long, 0)
	if len([]rune(clipped)) != railClip+1 || !strings.HasSuffix(clipped, "…") {
		t.Fatalf("clipped %d %q", len([]rune(clipped)), clipped[:20])
	}
	if clipText("   ", 1) != "Attachment" {
		t.Fatal("attachment clip")
	}
}

func TestRailReadyCountAddsNobody(t *testing.T) {
	st := newRailState("general", nil)
	st.applyDispatch("READY", json.RawMessage(`{
		"user":{"id":"1","username":"rail","bot":true},
		"guilds":[{"id":"9","online_count":5,"channels":[{"id":"3","type":0,"name":"general"}]}],
		"presences":[{"user":{"id":"2","username":"alpha","global_name":"Alpha"},"status":"online"}]
	}`))
	view := st.view(time.Now())
	if !view.OK {
		t.Fatal("ready left the snapshot down")
	}
	if len(view.Online) != 0 {
		t.Fatalf("ready filled online %#v", view.Online)
	}
	if st.channelID != "3" || st.self != "1" {
		t.Fatalf("channel %s self %s", st.channelID, st.self)
	}
}

func TestRailGatewayFeedsMessagesAndPresence(t *testing.T) {
	st := newRailState("general", nil)
	st.applyDispatch("READY", json.RawMessage(`{"user":{"id":"1","username":"rail","bot":true}}`))
	st.applyDispatch("GUILD_CREATE", json.RawMessage(`{
		"id":"9",
		"channels":[{"id":"3","type":0,"name":"general"}],
		"online_count":4,
		"presences":[]
	}`))
	st.applyDispatch("GUILD_MEMBERS_CHUNK", json.RawMessage(`{
		"guild_id":"9",
		"members":[
			{"user":{"id":"2","username":"alpha","global_name":"Alpha","avatar":"abc"},"nick":null},
			{"user":{"id":"4","username":"beta","global_name":"Beta"},"nick":"Beta"}
		],
		"presences":[{"user":{"id":"2"},"status":"online"}],
		"chunk_index":0,
		"chunk_count":1
	}`))
	st.applyDispatch("PRESENCE_UPDATE", json.RawMessage(`{"user":{"id":"4"},"status":"idle","guild_id":"9"}`))
	st.applyDispatch("PRESENCE_UPDATE", json.RawMessage(`{"user":{"id":"4"},"status":"offline","guild_id":"9"}`))
	st.applyDispatch("GUILD_MEMBER_LIST_UPDATE", json.RawMessage(`{
		"guild_id":"9",
		"id":"3",
		"online_count":1,
		"ops":[{"op":"SYNC","range":[0,99],"items":[
			{"group":{"id":"online","count":2}},
			{"member":{"user":{"id":"2","username":"alpha","global_name":"Alpha","avatar":"abc"},"presence":{"status":"online","user":{"id":"2"}}}},
			{"member":{"user":{"id":"1","username":"rail","bot":true},"presence":{"status":"online","user":{"id":"1"}}}},
			{"group":{"id":"offline","count":1}},
			{"member":{"user":{"id":"4","username":"beta","global_name":"Beta"},"presence":{"status":"offline","user":{"id":"4"}}}}
		]}]
	}`))
	st.applyDispatch("MESSAGE_CREATE", json.RawMessage(`{
		"id":"20","channel_id":"3","timestamp":"2026-11-11T02:00:00.000Z",
		"content":"later note","author":{"id":"2","username":"alpha","global_name":"Alpha","avatar":"abc"}
	}`))
	st.applyDispatch("MESSAGE_CREATE", json.RawMessage(`{
		"id":"10","channel_id":"3","timestamp":"2026-11-11T01:00:00.000Z",
		"content":"earlier note","author":{"id":"4","username":"beta","global_name":"Beta"},
		"member":{"nick":"Beta"}
	}`))
	st.applyDispatch("MESSAGE_CREATE", json.RawMessage(`{
		"id":"11","channel_id":"8","timestamp":"2026-11-11T01:30:00.000Z",
		"content":"other room","author":{"id":"2","username":"alpha"}
	}`))
	view := st.view(time.Now())
	if len(view.Online) != 1 || view.Online[0].Name != "Alpha" || view.Online[0].Avatar != "/fluxer/avatar/2" {
		t.Fatalf("online %#v", view.Online)
	}
	if len(view.Messages) != 2 || view.Messages[0].Text != "earlier note" || view.Messages[1].Text != "later note" {
		t.Fatalf("messages %#v", view.Messages)
	}
	if view.Messages[0].Author != "Beta" || view.Messages[1].Author != "Alpha" {
		t.Fatalf("authors %#v", view.Messages)
	}
}

func TestRailSnapshotDownAndEmpty(t *testing.T) {
	st := newRailState("general", nil)
	down := st.view(time.Now())
	if down.OK || down.Messages == nil || down.Online == nil || len(down.Messages) != 0 || len(down.Online) != 0 {
		t.Fatalf("down %#v", down)
	}
	st.touch()
	empty := st.view(time.Now())
	if !empty.OK || len(empty.Messages) != 0 || len(empty.Online) != 0 {
		t.Fatalf("empty %#v", empty)
	}
	quiet := st.view(time.Now().Add(railFresh + time.Second))
	if quiet.OK {
		t.Fatal("stale snapshot stayed up")
	}
	srv := httptest.NewServer(newRailState("general", nil))
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/fluxer/snapshot")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body railView
	if json.NewDecoder(resp.Body).Decode(&body) != nil || body.OK {
		t.Fatalf("handler %#v", body)
	}
}

func TestRailMessagePollKeepsOldestLast(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bot placeholder-token" {
			http.Error(w, "auth", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `[
			{"id":"30","channel_id":"3","timestamp":"2026-11-11T03:00:00.000Z","content":"newest","author":{"id":"2","username":"alpha","global_name":"Alpha"}},
			{"id":"10","channel_id":"3","timestamp":"2026-11-11T01:00:00.000Z","content":"oldest","author":{"id":"2","username":"alpha","global_name":"Alpha"},"attachments":[{"id":"f"}]}
		]`)
	}))
	defer api.Close()
	st := newRailState("general", api.Client())
	st.setChannel("9", "3")
	if err := st.pollMessages(api.URL, "placeholder-token"); err != nil {
		t.Fatal(err)
	}
	view := st.view(time.Now())
	if len(view.Messages) != 2 || view.Messages[0].Text != "oldest" || view.Messages[1].Text != "newest" {
		t.Fatalf("order %#v", view.Messages)
	}
}

func TestRailGifEmbedStaysOnTheMediaHost(t *testing.T) {
	host := "media.example"
	raw, kind := pickEmbed([]fxEmbed{{
		Video: &fxEmbedMedia{
			ProxyURL:    "https://media.example/media/external/clip.webm",
			ContentType: "video/webm",
		},
		Thumbnail: &fxEmbedMedia{
			ProxyURL:    "https://cdn.example/still.webp",
			ContentType: "image/webp",
		},
	}}, nil, host)
	if raw != "https://media.example/media/external/clip.webm" || kind != "video" {
		t.Fatalf("embed %s %s", kind, raw)
	}
	if off, offKind := pickEmbed([]fxEmbed{{
		Video: &fxEmbedMedia{ProxyURL: "https://cdn.example/clip.webm", ContentType: "video/webm"},
	}}, nil, host); off != "" || offKind != "" {
		t.Fatalf("off-host embed %s %s", offKind, off)
	}
	gif, gifKind := pickEmbed(nil, []fxEmbedMedia{{
		ProxyURL:    "https://media.example/attachments/1.gif",
		ContentType: "image/gif",
	}}, host)
	if gif != "https://media.example/attachments/1.gif" || gifKind != "image" {
		t.Fatalf("gif %s %s", gifKind, gif)
	}
}

func TestRailEmbedProxy(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/media/external/clip.webm" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "video/webm")
		_, _ = w.Write([]byte("webm-bytes"))
	}))
	defer media.Close()
	st := newRailState("general", media.Client())
	if err := st.setMedia(media.URL); err != nil {
		t.Fatal(err)
	}
	st.lock()
	st.channelID = "3"
	st.unlock()
	st.applyDispatch("MESSAGE_CREATE", json.RawMessage(`{
		"id":"21","channel_id":"3","timestamp":"2026-11-11T03:00:00.000Z",
		"content":"https://klipy.com/gifs/clip",
		"author":{"id":"2","username":"alpha","global_name":"Alpha"},
		"embeds":[{"type":"gifv","video":{"proxy_url":"`+media.URL+`/media/external/clip.webm","content_type":"video/webm"}}]
	}`))
	view := st.view(time.Now())
	if len(view.Messages) != 1 || view.Messages[0].Embed != "/fluxer/embed/21" || view.Messages[0].Kind != "video" || view.Messages[0].Text != "" {
		t.Fatalf("snapshot %#v", view.Messages)
	}
	if captionBesideEmbed("look https://klipy.com/gifs/clip", true) != "look" {
		t.Fatal("caption lost its words")
	}
	srv := httptest.NewServer(st)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/fluxer/embed/21")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != "webm-bytes" || resp.Header.Get("Content-Type") != "video/webm" {
		t.Fatalf("embed %d %s %q", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
}

func TestRailAvatarProxy(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/avatars/2/abc.png" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("png-bytes"))
	}))
	defer media.Close()
	st := newRailState("general", media.Client())
	if err := st.setMedia(media.URL); err != nil {
		t.Fatal(err)
	}
	st.lock()
	st.members["2"] = &memberRec{name: "Alpha", hash: "abc"}
	st.unlock()
	srv := httptest.NewServer(st)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/fluxer/avatar/2")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != "png-bytes" || resp.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("avatar %d %s %q", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
	missing, err := http.Get(srv.URL + "/fluxer/avatar/9")
	if err != nil {
		t.Fatal(err)
	}
	missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("missing avatar %d", missing.StatusCode)
	}
}

func TestRailPresenceSubscriptionStaysSmall(t *testing.T) {
	st := newRailState("general", nil)
	st.lock()
	st.guildID = "9"
	st.channelID = "3"
	for i := 0; i < 5000; i++ {
		id := fmt.Sprintf("%019d", i+1)
		st.members[id] = &memberRec{name: id}
	}
	st.unlock()
	_, _, members := st.subscription()
	if len(members) != presenceSubs {
		t.Fatalf("subs %d", len(members))
	}
}

func TestRailFrameRoundTrip(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	_ = left.SetDeadline(time.Now().Add(2 * time.Second))
	_ = right.SetDeadline(time.Now().Add(2 * time.Second))
	writer := newWS(left, bufio.NewReader(left), bufio.NewWriter(left))
	reader := newWS(right, bufio.NewReader(right), bufio.NewWriter(right))
	payload := []byte(`{"op":10,"d":{"heartbeat_interval":1000}}`)
	errc := make(chan error, 1)
	go func() {
		errc <- writer.writeFrame(1, payload)
	}()
	op, fin, got, err := reader.readFrame()
	if err != nil {
		t.Fatal(err)
	}
	if writeErr := <-errc; writeErr != nil {
		t.Fatal(writeErr)
	}
	if op != 1 || !fin || string(got) != string(payload) {
		t.Fatalf("frame %d %v %s", op, fin, got)
	}
}

func TestRailSocketHandshake(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("v") != "1" || r.URL.Query().Get("encoding") != "json" {
			http.Error(w, "query", http.StatusBadRequest)
			return
		}
		hj, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "hijack", http.StatusInternalServerError)
			return
		}
		conn, rw, err := hj.Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		key := r.Header.Get("Sec-WebSocket-Key")
		if _, err := rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + wsAccept(key) + "\r\n\r\n"); err != nil {
			return
		}
		if _, err := rw.Write(dumpFrame(1, []byte(`{"op":10,"d":{"heartbeat_interval":1000}}`))); err != nil {
			return
		}
		_ = rw.Flush()
		<-release
	}))
	defer srv.Close()
	rawURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, err := dialGateway(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	body, err := conn.nextText()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"op":10`) {
		t.Fatalf("hello %s", body)
	}
}
