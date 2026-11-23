package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	wsGUID   = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxFrame = 8 << 20
	maxSend  = 16000
)

type wsConn struct {
	conn    net.Conn
	br      *bufio.Reader
	bw      *bufio.Writer
	wmu     chan struct{}
	haveSeq bool
	seq     int
}

func newWS(conn net.Conn, br *bufio.Reader, bw *bufio.Writer) *wsConn {
	return &wsConn{conn: conn, br: br, bw: bw, wmu: make(chan struct{}, 1)}
}

func (c *wsConn) lock() {
	c.wmu <- struct{}{}
}

func (c *wsConn) unlock() {
	<-c.wmu
}

func (c *wsConn) Close() error {
	return c.conn.Close()
}

func (c *wsConn) setSeq(seq int) {
	c.lock()
	c.haveSeq = true
	c.seq = seq
	c.unlock()
}

func (c *wsConn) heartbeat() []byte {
	c.lock()
	defer c.unlock()
	if !c.haveSeq {
		return []byte(`{"op":1,"d":null}`)
	}
	return []byte(fmt.Sprintf(`{"op":1,"d":%d}`, c.seq))
}

func wsAccept(key string) string {
	sum := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func withGatewayQuery(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if u.Scheme != "ws" && u.Scheme != "wss" {
		return "", fmt.Errorf("gateway scheme is incomplete")
	}
	q := u.Query()
	q.Set("v", "1")
	q.Set("encoding", "json")
	q.Del("compress")
	q.Del("stream")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func dialGateway(raw string) (*wsConn, error) {
	full, err := withGatewayQuery(raw)
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(full)
	if err != nil {
		return nil, err
	}
	host := u.Host
	if !strings.Contains(host, ":") {
		if u.Scheme == "wss" {
			host += ":443"
		} else {
			host += ":80"
		}
	}
	netConn, err := (&net.Dialer{Timeout: 10 * time.Second}).Dial("tcp", host)
	if err != nil {
		return nil, err
	}
	if u.Scheme == "wss" {
		tlsConn := tls.Client(netConn, &tls.Config{ServerName: u.Hostname()})
		if err := tlsConn.Handshake(); err != nil {
			netConn.Close()
			return nil, err
		}
		netConn = tlsConn
	}
	br := bufio.NewReader(netConn)
	bw := bufio.NewWriter(netConn)
	keyRaw := make([]byte, 16)
	if _, err := rand.Read(keyRaw); err != nil {
		netConn.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(keyRaw)
	path := u.RequestURI()
	if path == "" {
		path = "/"
	}
	if _, err := fmt.Fprintf(bw, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", path, u.Host, key); err != nil {
		netConn.Close()
		return nil, err
	}
	if err := bw.Flush(); err != nil {
		netConn.Close()
		return nil, err
	}
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		netConn.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols || !strings.EqualFold(resp.Header.Get("Sec-WebSocket-Accept"), wsAccept(key)) {
		netConn.Close()
		return nil, fmt.Errorf("gateway handshake status %d", resp.StatusCode)
	}
	return newWS(netConn, br, bw), nil
}

func dumpFrame(op byte, payload []byte) []byte {
	out := []byte{0x80 | op}
	n := len(payload)
	switch {
	case n < 126:
		out = append(out, byte(n))
	case n < 65536:
		out = append(out, 126, byte(n>>8), byte(n))
	default:
		out = append(out, 127)
		var ext [8]byte
		for i := 0; i < 8; i++ {
			ext[7-i] = byte(n >> (8 * i))
		}
		out = append(out, ext[:]...)
	}
	return append(out, payload...)
}

func (c *wsConn) writeFrame(op byte, payload []byte) error {
	if len(payload) > maxSend {
		return fmt.Errorf("gateway command is too large")
	}
	c.lock()
	defer c.unlock()
	header := []byte{0x80 | op}
	n := len(payload)
	switch {
	case n < 126:
		header = append(header, 0x80|byte(n))
	case n < 65536:
		header = append(header, 0x80|126, byte(n>>8), byte(n))
	default:
		header = append(header, 0x80|127)
		var ext [8]byte
		for i := 0; i < 8; i++ {
			ext[7-i] = byte(n >> (8 * i))
		}
		header = append(header, ext[:]...)
	}
	mask := make([]byte, 4)
	if _, err := rand.Read(mask); err != nil {
		return err
	}
	header = append(header, mask...)
	masked := make([]byte, n)
	for i := 0; i < n; i++ {
		masked[i] = payload[i] ^ mask[i&3]
	}
	if _, err := c.bw.Write(header); err != nil {
		return err
	}
	if _, err := c.bw.Write(masked); err != nil {
		return err
	}
	return c.bw.Flush()
}

func (c *wsConn) readFrame() (byte, bool, []byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(c.br, hdr[:]); err != nil {
		return 0, false, nil, err
	}
	fin := hdr[0]&0x80 != 0
	op := hdr[0] & 0x0f
	masked := hdr[1]&0x80 != 0
	var ln uint64
	switch hdr[1] & 0x7f {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return 0, false, nil, err
		}
		ln = uint64(ext[0])<<8 | uint64(ext[1])
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return 0, false, nil, err
		}
		for _, b := range ext {
			ln = ln<<8 | uint64(b)
		}
	default:
		ln = uint64(hdr[1] & 0x7f)
	}
	if ln > maxFrame {
		return 0, false, nil, fmt.Errorf("gateway frame is too large")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(c.br, mask[:]); err != nil {
			return 0, false, nil, err
		}
	}
	payload := make([]byte, ln)
	if _, err := io.ReadFull(c.br, payload); err != nil {
		return 0, false, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i&3]
		}
	}
	return op, fin, payload, nil
}

func (c *wsConn) nextText() ([]byte, error) {
	var msg []byte
	started := false
	for {
		_ = c.conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		op, fin, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch op {
		case 1:
			msg = append(msg[:0], payload...)
			started = true
			if fin {
				return msg, nil
			}
		case 0:
			if !started {
				return nil, fmt.Errorf("gateway frame is out of order")
			}
			msg = append(msg, payload...)
			if len(msg) > maxFrame {
				return nil, fmt.Errorf("gateway message is too large")
			}
			if fin {
				return msg, nil
			}
		case 8:
			return nil, fmt.Errorf("gateway closed")
		case 9:
			if len(payload) > 125 {
				payload = payload[:125]
			}
			if err := c.writeFrame(10, payload); err != nil {
				return nil, err
			}
		default:
		}
	}
}
