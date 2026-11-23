package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
	"unicode"
)

const (
	railMessages    = 30
	railClip        = 120
	railFresh       = 8 * time.Second
	presenceSubs    = 300
	avatarCacheFor  = 5 * time.Minute
	avatarByteLimit = 512 << 10
	embedByteLimit  = 2 << 20
)

type railConfig struct {
	origin    string
	listen    string
	tokenFile string
	channel   string
}

type discovery struct {
	API     string
	Gateway string
	Media   string
}

type fxUser struct {
	ID         string          `json:"id"`
	Username   string          `json:"username"`
	GlobalName *string         `json:"global_name"`
	Avatar     json.RawMessage `json:"avatar"`
	Bot        bool            `json:"bot"`
	System     bool            `json:"system"`
}

func (u fxUser) avatarHash() (string, bool) {
	if len(u.Avatar) == 0 {
		return "", false
	}
	if string(u.Avatar) == "null" {
		return "", true
	}
	var hash string
	if json.Unmarshal(u.Avatar, &hash) != nil {
		return "", false
	}
	return hash, true
}

type fxPresence struct {
	User    fxUser `json:"user"`
	Status  string `json:"status"`
	GuildID string `json:"guild_id"`
}

type fxMember struct {
	User     fxUser      `json:"user"`
	Nick     *string     `json:"nick"`
	Presence *fxPresence `json:"presence"`
}

type fxChannel struct {
	ID   string `json:"id"`
	Type int    `json:"type"`
	Name string `json:"name"`
}

type fxMessage struct {
	ID          string         `json:"id"`
	ChannelID   string         `json:"channel_id"`
	Author      fxUser         `json:"author"`
	Content     string         `json:"content"`
	Timestamp   string         `json:"timestamp"`
	Attachments []fxEmbedMedia `json:"attachments"`
	Embeds      []fxEmbed      `json:"embeds"`
	Stickers    []struct {
		ID string `json:"id"`
	} `json:"stickers"`
	Member *struct {
		Nick *string `json:"nick"`
	} `json:"member"`
}

type memberRec struct {
	name   string
	hash   string
	bot    bool
	system bool
}

type fxEmbedMedia struct {
	ProxyURL    string `json:"proxy_url"`
	ContentType string `json:"content_type"`
}

type fxEmbed struct {
	Video     *fxEmbedMedia `json:"video"`
	Image     *fxEmbedMedia `json:"image"`
	Thumbnail *fxEmbedMedia `json:"thumbnail"`
}

type storedMessage struct {
	ID        string
	UserID    string
	Author    string
	At        string
	Text      string
	EmbedURL  string
	EmbedKind string
}

type railMessage struct {
	Author string `json:"author"`
	At     string `json:"at"`
	Text   string `json:"text"`
	Avatar string `json:"avatar,omitempty"`
	Embed  string `json:"embed,omitempty"`
	Kind   string `json:"kind,omitempty"`
}

type railPerson struct {
	Name   string `json:"name"`
	Avatar string `json:"avatar,omitempty"`
}

type railView struct {
	OK       bool          `json:"ok"`
	Messages []railMessage `json:"messages"`
	Online   []railPerson  `json:"online"`
}

type cachedAvatar struct {
	body  []byte
	ctype string
	at    time.Time
}

type railState struct {
	channelName string
	http        *http.Client

	mu         chan struct{}
	self       string
	guildID    string
	channelID  string
	mediaBase  string
	mediaHost  string
	socketOpen bool
	ready      bool
	ok         bool
	fresh      time.Time
	members    map[string]*memberRec
	status     map[string]string
	messages   []storedMessage
	avatars    map[string]cachedAvatar
	embeds     map[string]cachedAvatar
}

func newRailState(channel string, client *http.Client) *railState {
	if channel == "" {
		channel = "general"
	}
	return &railState{
		channelName: channel,
		http:        client,
		mu:          make(chan struct{}, 1),
		members:     map[string]*memberRec{},
		status:      map[string]string{},
		messages:    []storedMessage{},
		avatars:     map[string]cachedAvatar{},
		embeds:      map[string]cachedAvatar{},
	}
}

func (s *railState) lock()   { s.mu <- struct{}{} }
func (s *railState) unlock() { <-s.mu }

func railConfigFromEnv() (railConfig, error) {
	cfg := railConfig{
		origin:    strings.TrimRight(os.Getenv("FLUXER_ORIGIN"), "/"),
		listen:    os.Getenv("FLUXER_LISTEN"),
		tokenFile: os.Getenv("FLUXER_TOKEN_FILE"),
		channel:   os.Getenv("FLUXER_CHANNEL"),
	}
	if cfg.channel == "" {
		cfg.channel = "general"
	}
	if cfg.listen == "" {
		cfg.listen = "127.0.0.1:8094"
	}
	if cfg.origin == "" {
		return cfg, fmt.Errorf("FLUXER_ORIGIN is unset")
	}
	host, _, err := net.SplitHostPort(cfg.listen)
	if err != nil {
		return cfg, err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return cfg, fmt.Errorf("listen address is outside loopback")
	}
	return cfg, nil
}

func cmdFluxerRail(args []string) error {
	if err := needArgs("fluxer-rail", args, 0); err != nil {
		return err
	}
	cfg, err := railConfigFromEnv()
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: stayOnHost}
	st := newRailState(cfg.channel, client)
	ln, err := net.Listen("tcp", cfg.listen)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: st}
	go func() { _ = srv.Serve(ln) }()
	log.Printf("fluxer-rail: listening on %s", cfg.listen)
	for {
		err := st.session(cfg)
		delay := 3 * time.Second
		if err != nil {
			log.Printf("fluxer-rail: %s", err)
			if cfg.tokenFile == "" || strings.Contains(err.Error(), "token file") {
				delay = 30 * time.Second
			}
		}
		time.Sleep(delay)
	}
}

func stayOnHost(req *http.Request, via []*http.Request) error {
	if len(via) == 0 || len(via) > 3 {
		return fmt.Errorf("redirect left the request host")
	}
	if !strings.EqualFold(req.URL.Host, via[0].URL.Host) {
		return fmt.Errorf("redirect left the request host")
	}
	return nil
}

func (s *railState) session(cfg railConfig) error {
	if cfg.tokenFile == "" {
		return fmt.Errorf("token file is unset")
	}
	token, err := readToken(cfg.tokenFile)
	if err != nil {
		return err
	}
	disc, err := discover(s.http, cfg.origin)
	if err != nil {
		return err
	}
	if err := s.setMedia(disc.Media); err != nil {
		return err
	}
	guild, channel, err := findGeneral(s.http, disc.API, token, s.channelName)
	if err != nil {
		return err
	}
	s.setChannel(guild, channel)
	if err := s.pollMessages(disc.API, token); err != nil {
		log.Printf("fluxer-rail: message poll status %s", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.pollLoop(ctx, disc.API, token)
	return runGateway(ctx, s, disc.Gateway, token)
}

func (s *railState) pollLoop(ctx context.Context, api, token string) {
	tick := time.NewTicker(4 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if err := s.pollMessages(api, token); err != nil {
				log.Printf("fluxer-rail: message poll status %s", err)
			}
		}
	}
}

func readToken(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("token file")
	}
	text := strings.TrimSpace(string(raw))
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = strings.TrimSpace(text[:i])
	}
	if key, val, ok := strings.Cut(text, "="); ok && strings.Contains(strings.ToUpper(key), "TOKEN") {
		text = strings.Trim(strings.TrimSpace(val), `"'`)
	}
	if text == "" || strings.ContainsAny(text, " \t") {
		return "", fmt.Errorf("token file is empty")
	}
	return text, nil
}

func parseDiscovery(body []byte) (discovery, error) {
	var doc struct {
		Endpoints struct {
			APIPublic string `json:"api_public"`
			Gateway   string `json:"gateway"`
			Media     string `json:"media"`
		} `json:"endpoints"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return discovery{}, err
	}
	out := discovery{
		API:     strings.TrimRight(doc.Endpoints.APIPublic, "/"),
		Gateway: doc.Endpoints.Gateway,
		Media:   strings.TrimRight(doc.Endpoints.Media, "/"),
	}
	if !absoluteHTTP(out.API) || !absoluteHTTP(out.Media) {
		return discovery{}, fmt.Errorf("discovery endpoints are incomplete")
	}
	gu, err := url.Parse(out.Gateway)
	if err != nil || (gu.Scheme != "ws" && gu.Scheme != "wss") || gu.Host == "" {
		return discovery{}, fmt.Errorf("discovery gateway is incomplete")
	}
	return out, nil
}

func absoluteHTTP(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Host != ""
}

func discover(client *http.Client, origin string) (discovery, error) {
	req, err := http.NewRequest(http.MethodGet, origin+"/.well-known/fluxer", nil)
	if err != nil {
		return discovery{}, err
	}
	req.Header.Set("User-Agent", "fluxer-rail")
	resp, err := client.Do(req)
	if err != nil {
		return discovery{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return discovery{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return discovery{}, fmt.Errorf("discovery status %d", resp.StatusCode)
	}
	return parseDiscovery(body)
}

func botGet(client *http.Client, rawURL, token string) ([]byte, int, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bot "+token)
	req.Header.Set("User-Agent", "fluxer-rail")
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return body, resp.StatusCode, err
}

func pickGeneral(channels []fxChannel, want string) (string, bool) {
	fallback := ""
	for _, ch := range channels {
		if !strings.EqualFold(strings.TrimSpace(ch.Name), want) || ch.ID == "" {
			continue
		}
		if ch.Type == 0 {
			return ch.ID, true
		}
		if ch.Type == 5 && fallback == "" {
			fallback = ch.ID
		}
	}
	if fallback != "" {
		return fallback, true
	}
	return "", false
}

func findGeneral(client *http.Client, api, token, name string) (string, string, error) {
	body, status, err := botGet(client, api+"/v1/users/@me/guilds?limit=200", token)
	if err != nil {
		return "", "", err
	}
	if status != http.StatusOK {
		return "", "", fmt.Errorf("guild list status %d", status)
	}
	var guilds []struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(body, &guilds) != nil {
		return "", "", fmt.Errorf("guild list is incomplete")
	}
	for _, guild := range guilds {
		if guild.ID == "" {
			continue
		}
		body, status, err = botGet(client, api+"/v1/guilds/"+guild.ID+"/channels", token)
		if err != nil {
			return "", "", err
		}
		if status != http.StatusOK {
			continue
		}
		var channels []fxChannel
		if json.Unmarshal(body, &channels) != nil {
			continue
		}
		if id, ok := pickGeneral(channels, name); ok {
			return guild.ID, id, nil
		}
	}
	return "", "", fmt.Errorf("channel %s is absent", name)
}

func (s *railState) setMedia(base string) error {
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return fmt.Errorf("media endpoint is incomplete")
	}
	s.lock()
	s.mediaBase = strings.TrimRight(base, "/")
	s.mediaHost = u.Host
	s.unlock()
	return nil
}

func (s *railState) setChannel(guild, channel string) {
	s.lock()
	s.guildID = guild
	s.channelID = channel
	s.unlock()
}

func (s *railState) setReady(ready bool) {
	s.lock()
	s.ready = ready
	s.unlock()
}

func (s *railState) setSocket(open bool) {
	s.lock()
	s.socketOpen = open
	if open {
		s.fresh = time.Now()
		s.ok = true
	}
	s.unlock()
}

func (s *railState) touch() {
	s.lock()
	s.fresh = time.Now()
	s.ok = true
	s.unlock()
}

func clipText(content string, extras int) string {
	var b strings.Builder
	space := false
	for _, r := range content {
		if r == '\n' || r == '\r' || r == '\t' || unicode.IsControl(r) {
			r = ' '
		}
		if r == ' ' {
			if space || b.Len() == 0 {
				continue
			}
			space = true
			b.WriteRune(' ')
			continue
		}
		space = false
		b.WriteRune(r)
	}
	text := strings.TrimSpace(b.String())
	runes := []rune(text)
	if len(runes) > railClip {
		text = strings.TrimSpace(string(runes[:railClip])) + "…"
	}
	if text == "" && extras > 0 {
		return "Attachment"
	}
	return text
}

func linkOnly(text string) bool {
	parsed, err := url.Parse(text)
	if err != nil || parsed.Host == "" {
		return false
	}
	return parsed.Scheme == "https" || parsed.Scheme == "http"
}

func captionBesideEmbed(text string, embedded bool) string {
	if !embedded {
		return text
	}
	if text == "Attachment" {
		return ""
	}
	parts := strings.Fields(text)
	kept := make([]string, 0, len(parts))
	for _, part := range parts {
		if linkOnly(strings.Trim(part, "<>()[]")) {
			continue
		}
		kept = append(kept, part)
	}
	return strings.Join(kept, " ")
}

func visibleStatus(status string) bool {
	switch status {
	case "online", "idle", "dnd":
		return true
	default:
		return false
	}
}

func (s *railState) remember(user fxUser, nick *string) {
	if user.ID == "" {
		return
	}
	rec := s.members[user.ID]
	if rec == nil {
		rec = &memberRec{name: "Someone"}
		s.members[user.ID] = rec
	}
	if nick != nil && strings.TrimSpace(*nick) != "" {
		rec.name = strings.TrimSpace(*nick)
	} else if user.GlobalName != nil && strings.TrimSpace(*user.GlobalName) != "" {
		rec.name = strings.TrimSpace(*user.GlobalName)
	} else if user.Username != "" {
		rec.name = user.Username
	}
	if user.Bot {
		rec.bot = true
	}
	if user.System {
		rec.system = true
	}
	if hash, ok := user.avatarHash(); ok {
		rec.hash = hash
	}
}

func sortMessages(list []storedMessage) {
	sort.Slice(list, func(i, j int) bool {
		if list[i].At == list[j].At {
			return list[i].ID < list[j].ID
		}
		return list[i].At < list[j].At
	})
}

func trimMessages(list []storedMessage) []storedMessage {
	if len(list) > railMessages {
		return list[len(list)-railMessages:]
	}
	return list
}

func (s *railState) pollMessages(api, token string) error {
	s.lock()
	channel := s.channelID
	s.unlock()
	if channel == "" {
		return fmt.Errorf("channel is unset")
	}
	body, status, err := botGet(s.http, api+"/v1/channels/"+channel+"/messages?limit=30", token)
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return fmt.Errorf("%d", status)
	}
	var raw []fxMessage
	if json.Unmarshal(body, &raw) != nil {
		return fmt.Errorf("messages are incomplete")
	}
	list := make([]storedMessage, 0, len(raw))
	s.lock()
	defer s.unlock()
	for _, msg := range raw {
		text := clipText(msg.Content, len(msg.Attachments)+len(msg.Stickers))
		embedURL, embedKind := pickEmbed(msg.Embeds, msg.Attachments, s.mediaHost)
		text = captionBesideEmbed(text, embedURL != "")
		if msg.ID == "" || (text == "" && embedURL == "") {
			continue
		}
		var nick *string
		if msg.Member != nil {
			nick = msg.Member.Nick
		}
		s.remember(msg.Author, nick)
		name := "Someone"
		if rec := s.members[msg.Author.ID]; rec != nil {
			name = rec.name
		}
		list = append(list, storedMessage{
			ID: msg.ID, UserID: msg.Author.ID, Author: name, At: msg.Timestamp, Text: text,
			EmbedURL: embedURL, EmbedKind: embedKind,
		})
	}
	sortMessages(list)
	s.messages = trimMessages(list)
	s.fresh = time.Now()
	s.ok = true
	return nil
}

func (s *railState) applyDispatch(name string, data json.RawMessage) {
	s.lock()
	defer s.unlock()
	s.fresh = time.Now()
	s.ok = true
	if len(data) == 0 || string(data) == "null" {
		return
	}
	switch name {
	case "READY":
		s.applyReady(data)
	case "GUILD_CREATE":
		s.applyGuild(data)
	case "MESSAGE_CREATE", "MESSAGE_UPDATE":
		s.applyMessage(data)
	case "MESSAGE_DELETE":
		s.applyDelete(data)
	case "PRESENCE_UPDATE":
		var p fxPresence
		if json.Unmarshal(data, &p) == nil {
			s.applyPresence(p)
		}
	case "PRESENCE_UPDATE_BULK":
		var bulk struct {
			Presences []fxPresence `json:"presences"`
		}
		if json.Unmarshal(data, &bulk) == nil {
			for _, p := range bulk.Presences {
				s.applyPresence(p)
			}
		}
	case "GUILD_MEMBERS_CHUNK":
		s.applyChunk(data)
	case "GUILD_MEMBER_LIST_UPDATE":
		s.applyMemberList(data)
	case "GUILD_MEMBER_REMOVE":
		var body struct {
			User struct {
				ID string `json:"id"`
			} `json:"user"`
		}
		if json.Unmarshal(data, &body) == nil && body.User.ID != "" {
			delete(s.status, body.User.ID)
		}
	}
}

func (s *railState) applyReady(data json.RawMessage) {
	var ready struct {
		User   fxUser `json:"user"`
		Guilds []struct {
			ID       string      `json:"id"`
			Channels []fxChannel `json:"channels"`
		} `json:"guilds"`
	}
	if json.Unmarshal(data, &ready) != nil {
		return
	}
	s.ready = true
	if ready.User.ID != "" {
		s.self = ready.User.ID
		s.remember(ready.User, nil)
	}
	for _, guild := range ready.Guilds {
		if id, ok := pickGeneral(guild.Channels, s.channelName); ok {
			s.guildID = guild.ID
			s.channelID = id
		}
	}
}

func (s *railState) applyGuild(data json.RawMessage) {
	var guild struct {
		ID          string      `json:"id"`
		Unavailable bool        `json:"unavailable"`
		Channels    []fxChannel `json:"channels"`
		Members     []fxMember  `json:"members"`
	}
	if json.Unmarshal(data, &guild) != nil || guild.Unavailable {
		return
	}
	for _, member := range guild.Members {
		s.remember(member.User, member.Nick)
	}
	if id, ok := pickGeneral(guild.Channels, s.channelName); ok {
		s.guildID = guild.ID
		s.channelID = id
	}
}

func (s *railState) applyPresence(p fxPresence) {
	if p.User.ID == "" {
		return
	}
	s.remember(p.User, nil)
	if p.Status == "" {
		p.Status = "offline"
	}
	s.status[p.User.ID] = p.Status
}

func (s *railState) applyMessage(data json.RawMessage) {
	var msg fxMessage
	if json.Unmarshal(data, &msg) != nil || msg.ID == "" {
		return
	}
	if s.channelID == "" || msg.ChannelID != s.channelID {
		return
	}
	text := clipText(msg.Content, len(msg.Attachments)+len(msg.Stickers))
	embedURL, embedKind := pickEmbed(msg.Embeds, msg.Attachments, s.mediaHost)
	text = captionBesideEmbed(text, embedURL != "")
	if text == "" && embedURL == "" {
		return
	}
	var nick *string
	if msg.Member != nil {
		nick = msg.Member.Nick
	}
	s.remember(msg.Author, nick)
	name := "Someone"
	if rec := s.members[msg.Author.ID]; rec != nil {
		name = rec.name
	}
	for i := range s.messages {
		if s.messages[i].ID == msg.ID {
			s.messages[i].Text = text
			s.messages[i].Author = name
			s.messages[i].UserID = msg.Author.ID
			s.messages[i].EmbedURL = embedURL
			s.messages[i].EmbedKind = embedKind
			return
		}
	}
	s.messages = append(s.messages, storedMessage{
		ID: msg.ID, UserID: msg.Author.ID, Author: name, At: msg.Timestamp, Text: text,
		EmbedURL: embedURL, EmbedKind: embedKind,
	})
	sortMessages(s.messages)
	s.messages = trimMessages(s.messages)
}

func (s *railState) applyDelete(data json.RawMessage) {
	var body struct {
		ID        string `json:"id"`
		ChannelID string `json:"channel_id"`
	}
	if json.Unmarshal(data, &body) != nil || body.ID == "" {
		return
	}
	if s.channelID != "" && body.ChannelID != "" && body.ChannelID != s.channelID {
		return
	}
	kept := s.messages[:0]
	for _, msg := range s.messages {
		if msg.ID != body.ID {
			kept = append(kept, msg)
		}
	}
	s.messages = kept
}

func (s *railState) applyChunk(data json.RawMessage) {
	var chunk struct {
		Members   []fxMember   `json:"members"`
		Presences []fxPresence `json:"presences"`
	}
	if json.Unmarshal(data, &chunk) != nil {
		return
	}
	online := map[string]fxPresence{}
	for _, p := range chunk.Presences {
		if p.User.ID != "" {
			online[p.User.ID] = p
		}
	}
	for _, member := range chunk.Members {
		s.remember(member.User, member.Nick)
		if member.User.ID == "" {
			continue
		}
		if p, ok := online[member.User.ID]; ok {
			s.remember(p.User, nil)
			status := p.Status
			if status == "" {
				status = "offline"
			}
			s.status[member.User.ID] = status
			continue
		}
		s.status[member.User.ID] = "offline"
	}
}

func (s *railState) applyMemberList(data json.RawMessage) {
	var body struct {
		Ops []struct {
			Range []int `json:"range"`
			Items []struct {
				Member *fxMember `json:"member"`
			} `json:"items"`
		} `json:"ops"`
	}
	if json.Unmarshal(data, &body) != nil {
		return
	}
	reset := false
	for _, op := range body.Ops {
		if len(op.Range) == 2 && op.Range[0] == 0 {
			reset = true
		}
	}
	if reset {
		s.status = map[string]string{}
	}
	for _, op := range body.Ops {
		for _, item := range op.Items {
			if item.Member == nil || item.Member.User.ID == "" {
				continue
			}
			s.remember(item.Member.User, item.Member.Nick)
			status := "offline"
			if item.Member.Presence != nil && item.Member.Presence.Status != "" {
				status = item.Member.Presence.Status
			}
			s.status[item.Member.User.ID] = status
		}
	}
}

func (s *railState) view(now time.Time) railView {
	s.lock()
	defer s.unlock()
	ok := s.socketOpen || (s.ok && !s.fresh.IsZero() && now.Sub(s.fresh) < railFresh)
	view := railView{OK: ok, Messages: []railMessage{}, Online: []railPerson{}}
	if !ok {
		return view
	}
	for _, msg := range s.messages {
		item := railMessage{Author: msg.Author, At: msg.At, Text: msg.Text}
		if rec := s.members[msg.UserID]; rec != nil && rec.hash != "" {
			item.Avatar = "/fluxer/avatar/" + msg.UserID
		}
		if msg.EmbedURL != "" && msg.EmbedKind != "" {
			item.Embed = "/fluxer/embed/" + msg.ID
			item.Kind = msg.EmbedKind
		}
		view.Messages = append(view.Messages, item)
	}
	for id, status := range s.status {
		if !visibleStatus(status) || id == s.self {
			continue
		}
		rec := s.members[id]
		if rec == nil || rec.bot || rec.system {
			continue
		}
		person := railPerson{Name: rec.name}
		if rec.hash != "" {
			person.Avatar = "/fluxer/avatar/" + id
		}
		view.Online = append(view.Online, person)
	}
	sort.Slice(view.Online, func(i, j int) bool {
		return strings.ToLower(view.Online[i].Name) < strings.ToLower(view.Online[j].Name)
	})
	return view
}

func (s *railState) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	switch {
	case r.URL.Path == "/fluxer/snapshot":
		s.serveSnapshot(w, r)
	case strings.HasPrefix(r.URL.Path, "/fluxer/avatar/"):
		id := strings.TrimPrefix(r.URL.Path, "/fluxer/avatar/")
		if !snowflake(id) {
			http.NotFound(w, r)
			return
		}
		s.serveAvatar(w, r, id)
	case strings.HasPrefix(r.URL.Path, "/fluxer/embed/"):
		id := strings.TrimPrefix(r.URL.Path, "/fluxer/embed/")
		if !snowflake(id) {
			http.NotFound(w, r)
			return
		}
		s.serveEmbed(w, r, id)
	default:
		http.NotFound(w, r)
	}
}

func snowflake(id string) bool {
	if id == "" || len(id) > 32 {
		return false
	}
	for _, r := range id {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (s *railState) serveSnapshot(w http.ResponseWriter, r *http.Request) {
	body, err := json.Marshal(s.view(time.Now()))
	if err != nil {
		http.Error(w, "snapshot", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(body)
}

func avatarMediaURL(base, userID, hash string) string {
	ext := "png"
	if strings.HasPrefix(hash, "a_") {
		ext = "gif"
	}
	return strings.TrimRight(base, "/") + "/avatars/" + url.PathEscape(userID) + "/" + url.PathEscape(hash) + "." + ext
}

func (s *railState) serveAvatar(w http.ResponseWriter, r *http.Request, id string) {
	s.lock()
	rec := s.members[id]
	base := s.mediaBase
	host := s.mediaHost
	hash := ""
	if rec != nil {
		hash = rec.hash
	}
	cached, ok := s.avatars[id+"/"+hash]
	fresh := ok && time.Since(cached.at) < avatarCacheFor
	s.unlock()
	if hash == "" || base == "" {
		http.NotFound(w, r)
		return
	}
	if !fresh {
		rawURL := avatarMediaURL(base, id, hash)
		u, err := url.Parse(rawURL)
		if err != nil || !strings.EqualFold(u.Host, host) {
			http.NotFound(w, r)
			return
		}
		body, ctype, err := s.fetchAvatar(rawURL)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		cached = cachedAvatar{body: body, ctype: ctype, at: time.Now()}
		s.lock()
		s.avatars[id+"/"+hash] = cached
		s.unlock()
	}
	w.Header().Set("Content-Type", cached.ctype)
	w.Header().Set("Cache-Control", "private, max-age=60")
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(cached.body)
}

func (s *railState) fetchAvatar(rawURL string) ([]byte, string, error) {
	if s.http == nil {
		return nil, "", fmt.Errorf("avatar client is unset")
	}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", "fluxer-rail")
	resp, err := s.http.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("avatar status %d", resp.StatusCode)
	}
	ctype := resp.Header.Get("Content-Type")
	if !strings.HasPrefix(ctype, "image/") {
		return nil, "", fmt.Errorf("avatar media type")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, avatarByteLimit+1))
	if err != nil {
		return nil, "", err
	}
	if len(body) == 0 || len(body) > avatarByteLimit {
		return nil, "", fmt.Errorf("avatar size")
	}
	return body, ctype, nil
}

func mediaKind(ctype string) string {
	ctype = strings.ToLower(strings.TrimSpace(ctype))
	if i := strings.IndexByte(ctype, ';'); i >= 0 {
		ctype = strings.TrimSpace(ctype[:i])
	}
	switch ctype {
	case "video/webm", "video/mp4":
		return "video"
	case "image/gif":
		return "image"
	default:
		return ""
	}
}

func hosted(raw, host string) (string, bool) {
	if host == "" || raw == "" {
		return "", false
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return "", false
	}
	if !strings.EqualFold(parsed.Host, host) {
		return "", false
	}
	return parsed.String(), true
}

func firstHosted(parts []*fxEmbedMedia, host string) (string, string) {
	for _, part := range parts {
		if part == nil {
			continue
		}
		kind := mediaKind(part.ContentType)
		if kind == "" {
			continue
		}
		raw, ok := hosted(part.ProxyURL, host)
		if ok {
			return raw, kind
		}
	}
	return "", ""
}

func pickEmbed(embeds []fxEmbed, attachments []fxEmbedMedia, host string) (string, string) {
	videos := make([]*fxEmbedMedia, 0, len(embeds)+len(attachments))
	images := make([]*fxEmbedMedia, 0, len(embeds)*2+len(attachments))
	for i := range embeds {
		videos = append(videos, embeds[i].Video)
		images = append(images, embeds[i].Image, embeds[i].Thumbnail)
	}
	for i := range attachments {
		switch mediaKind(attachments[i].ContentType) {
		case "video":
			videos = append(videos, &attachments[i])
		case "image":
			images = append(images, &attachments[i])
		}
	}
	if raw, kind := firstHosted(videos, host); raw != "" {
		return raw, kind
	}
	return firstHosted(images, host)
}

func (s *railState) serveEmbed(w http.ResponseWriter, r *http.Request, id string) {
	s.lock()
	var rawURL, host, kind string
	for _, msg := range s.messages {
		if msg.ID == id {
			rawURL = msg.EmbedURL
			kind = msg.EmbedKind
			break
		}
	}
	host = s.mediaHost
	key := id + "\n" + rawURL
	cached, ok := s.embeds[key]
	fresh := ok && time.Since(cached.at) < avatarCacheFor
	s.unlock()
	checked, onHost := hosted(rawURL, host)
	if rawURL == "" || kind == "" || !onHost || checked != rawURL {
		http.NotFound(w, r)
		return
	}
	if !fresh {
		body, ctype, err := s.fetchEmbed(rawURL)
		if err != nil || mediaKind(ctype) != kind {
			http.NotFound(w, r)
			return
		}
		cached = cachedAvatar{body: body, ctype: ctype, at: time.Now()}
		s.lock()
		s.embeds[key] = cached
		s.unlock()
	}
	w.Header().Set("Content-Type", cached.ctype)
	w.Header().Set("Cache-Control", "private, max-age=60")
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(cached.body)
}

func (s *railState) fetchEmbed(rawURL string) ([]byte, string, error) {
	if s.http == nil {
		return nil, "", fmt.Errorf("embed client is unset")
	}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", "fluxer-rail")
	resp, err := s.http.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("embed status %d", resp.StatusCode)
	}
	ctype := resp.Header.Get("Content-Type")
	if mediaKind(ctype) == "" {
		return nil, "", fmt.Errorf("embed media type")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, embedByteLimit+1))
	if err != nil {
		return nil, "", err
	}
	if len(body) == 0 || len(body) > embedByteLimit {
		return nil, "", fmt.Errorf("embed size")
	}
	return body, strings.TrimSpace(strings.Split(ctype, ";")[0]), nil
}

func (s *railState) subscription() (string, string, []string) {
	s.lock()
	defer s.unlock()
	if s.guildID == "" || s.channelID == "" {
		return "", "", nil
	}
	members := make([]string, 0, len(s.members))
	for id := range s.members {
		if id == s.self || !snowflake(id) {
			continue
		}
		members = append(members, id)
	}
	sort.Strings(members)
	if len(members) > presenceSubs {
		members = members[:presenceSubs]
	}
	return s.guildID, s.channelID, members
}

func (s *railState) writeSubs(conn *wsConn, withMembers bool) error {
	s.lock()
	ready := s.ready
	s.unlock()
	if !ready {
		return nil
	}
	guild, channel, members := s.subscription()
	if guild == "" || channel == "" {
		return nil
	}
	lazy, err := json.Marshal(map[string]any{
		"op": 14,
		"d": map[string]any{
			"subscriptions": map[string]any{
				guild: map[string]any{
					"active":  true,
					"typing":  false,
					"members": members,
					"member_list_channels": map[string]any{
						channel: [][]int{{0, 99}},
					},
				},
			},
		},
	})
	if err != nil {
		return err
	}
	if len(lazy) > maxSend {
		return fmt.Errorf("gateway command is too large")
	}
	if err := conn.writeFrame(1, lazy); err != nil {
		return err
	}
	if !withMembers {
		return nil
	}
	req, err := json.Marshal(map[string]any{
		"op": 8,
		"d": map[string]any{
			"guild_id":  guild,
			"query":     "",
			"limit":     0,
			"presences": true,
			"nonce":     "rail",
		},
	})
	if err != nil {
		return err
	}
	return conn.writeFrame(1, req)
}

func runGateway(ctx context.Context, s *railState, gateway, token string) error {
	conn, err := dialGateway(gateway)
	if err != nil {
		return err
	}
	defer conn.Close()
	raw, err := conn.nextText()
	if err != nil {
		return err
	}
	var helloEnv struct {
		Op int             `json:"op"`
		D  json.RawMessage `json:"d"`
	}
	if json.Unmarshal(raw, &helloEnv) != nil || helloEnv.Op != 10 {
		return fmt.Errorf("gateway hello is missing")
	}
	var hello struct {
		Interval int `json:"heartbeat_interval"`
	}
	_ = json.Unmarshal(helloEnv.D, &hello)
	interval := time.Duration(hello.Interval) * time.Millisecond
	if interval < time.Second {
		interval = 20 * time.Second
	}
	s.setReady(false)
	defer s.setReady(false)
	s.setSocket(true)
	defer s.setSocket(false)
	session, cancel := context.WithCancel(ctx)
	defer cancel()
	go heartbeatLoop(session, conn, s, interval)
	go subscribeLoop(session, conn, s)
	body, err := json.Marshal(map[string]any{
		"op": 2,
		"d": map[string]any{
			"token": token,
			"properties": map[string]string{
				"os":      "Linux",
				"browser": "fluxer-rail",
				"device":  "fluxer-rail",
			},
			"presence": map[string]any{"status": "invisible"},
			"ignored_events": []string{
				"TYPING_START",
				"MESSAGE_REACTION_ADD",
				"MESSAGE_REACTION_REMOVE",
			},
		},
	})
	if err != nil {
		return err
	}
	if err := conn.writeFrame(1, body); err != nil {
		return err
	}
	for {
		raw, err := conn.nextText()
		if err != nil {
			return err
		}
		s.touch()
		var env struct {
			Op int             `json:"op"`
			D  json.RawMessage `json:"d"`
			S  *int            `json:"s"`
			T  string          `json:"t"`
		}
		if json.Unmarshal(raw, &env) != nil {
			continue
		}
		switch env.Op {
		case 0:
			if env.S != nil {
				conn.setSeq(*env.S)
			}
			s.applyDispatch(env.T, env.D)
			if env.T == "READY" || env.T == "GUILD_CREATE" {
				_ = s.writeSubs(conn, true)
			}
		case 1:
			_ = conn.writeFrame(1, conn.heartbeat())
		case 7, 9:
			return fmt.Errorf("gateway asked for a new session")
		}
	}
}

func heartbeatLoop(ctx context.Context, conn *wsConn, s *railState, interval time.Duration) {
	send := func() {
		if err := conn.writeFrame(1, conn.heartbeat()); err == nil {
			s.touch()
		}
	}
	send()
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			send()
		}
	}
}

func subscribeLoop(ctx context.Context, conn *wsConn, s *railState) {
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			n++
			_ = s.writeSubs(conn, n%2 == 0)
		}
	}
}
