package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type envelope struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *rpcError       `json:"error,omitempty"`
}

type rpcResponse struct {
	result json.RawMessage
	err    error
}

type streamEvent struct {
	name string
	data any
}

type socketHub struct {
	mu      sync.RWMutex
	clients map[chan []byte]struct{}
}

func newSocketHub() *socketHub {
	return &socketHub{clients: make(map[chan []byte]struct{})}
}

func (h *socketHub) subscribe() chan []byte {
	ch := make(chan []byte, 512)
	h.mu.Lock()
	h.clients[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *socketHub) unsubscribe(ch chan []byte) {
	h.mu.Lock()
	delete(h.clients, ch)
	h.mu.Unlock()
}

func (h *socketHub) broadcast(value any) {
	data, err := json.Marshal(value)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for ch := range h.clients {
		select {
		case ch <- data:
		default:
			log.Printf("dropping realtime event for a slow browser")
		}
	}
}

type Codex struct {
	cmd       *exec.Cmd
	conn      *websocket.Conn
	endpoint  string
	writeMu   sync.Mutex
	pendingMu sync.Mutex
	pending   map[string]chan rpcResponse
	streamsMu sync.RWMutex
	streams   map[string]chan streamEvent
	knownMu   sync.Mutex
	known     map[string]bool
	hub       *socketHub
	nextID    atomic.Int64
	ready     atomic.Bool
	done      chan struct{}
	closeOnce sync.Once
}

func startCodex(bin, endpoint string) (*Codex, error) {
	// Reuse a compatible app-server that is already listening. This makes Go
	// restart-safe and lets a manually managed app-server remain the shared owner.
	probeCtx, probeCancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	existingConn, _, existingErr := websocket.Dial(probeCtx, endpoint, nil)
	probeCancel()
	if existingErr == nil {
		existingConn.SetReadLimit(16 * 1024 * 1024)
		c := &Codex{conn: existingConn, endpoint: endpoint, pending: make(map[string]chan rpcResponse), streams: make(map[string]chan streamEvent), known: make(map[string]bool), hub: newSocketHub(), done: make(chan struct{})}
		go c.readLoop()
		if err := c.initialize(); err != nil {
			c.conn.CloseNow()
			return nil, fmt.Errorf("initialize existing codex app-server: %w", err)
		}
		log.Printf("connected to existing Codex app-server at %s", endpoint)
		return c, nil
	}

	cmd := exec.Command(bin, "app-server", "--listen", endpoint)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}

	c := &Codex{cmd: cmd, endpoint: endpoint, pending: make(map[string]chan rpcResponse), streams: make(map[string]chan streamEvent), known: make(map[string]bool), hub: newSocketHub(), done: make(chan struct{})}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start codex: %w", err)
	}
	go logCodexOutput("stdout", stdout)
	go logCodexOutput("stderr", stderr)

	processExit := make(chan error, 1)
	go func() { processExit <- cmd.Wait() }()

	dialCtx, dialCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer dialCancel()
	for {
		conn, _, dialErr := websocket.Dial(dialCtx, endpoint, nil)
		if dialErr == nil {
			conn.SetReadLimit(16 * 1024 * 1024)
			c.conn = conn
			break
		}
		select {
		case processErr := <-processExit:
			return nil, fmt.Errorf("codex app-server exited before accepting connections: %v", processErr)
		case <-dialCtx.Done():
			_ = cmd.Process.Kill()
			return nil, fmt.Errorf("connect to codex app-server at %s: %w", endpoint, dialErr)
		case <-time.After(100 * time.Millisecond):
		}
	}

	go c.readLoop()
	go func() {
		err := <-processExit
		log.Printf("codex app-server process exited: %v", err)
	}()

	if err := c.initialize(); err != nil {
		c.conn.CloseNow()
		_ = cmd.Process.Kill()
		return nil, fmt.Errorf("initialize codex: %w", err)
	}
	log.Printf("started shared Codex app-server at %s", endpoint)
	return c, nil
}

func (c *Codex) initialize() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var initResult map[string]any
	if err := c.call(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]string{"name": "codex-web-bridge", "title": "Codex Local Web", "version": "0.1.0"},
		"capabilities": map[string]any{"experimentalApi": true},
	}, &initResult); err != nil {
		return err
	}
	if err := c.notify("initialized", nil); err != nil {
		return err
	}
	c.ready.Store(true)
	return nil
}

func logCodexOutput(stream string, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		log.Printf("codex %s: %s", stream, scanner.Text())
	}
}

func (c *Codex) notify(method string, params any) error {
	msg := map[string]any{"method": method}
	if params != nil {
		msg["params"] = params
	}
	return c.write(msg)
}

func (c *Codex) write(v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if c.conn == nil {
		return errors.New("codex app-server is not connected")
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return c.conn.Write(ctx, websocket.MessageText, payload)
}

func (c *Codex) call(ctx context.Context, method string, params any, out any) error {
	id := c.nextID.Add(1)
	key := strconv.FormatInt(id, 10)
	response := make(chan rpcResponse, 1)
	c.pendingMu.Lock()
	c.pending[key] = response
	c.pendingMu.Unlock()
	if err := c.write(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		c.removePending(key)
		return err
	}
	select {
	case got := <-response:
		if got.err != nil {
			return got.err
		}
		if out != nil && len(got.result) > 0 {
			return json.Unmarshal(got.result, out)
		}
		return nil
	case <-ctx.Done():
		c.removePending(key)
		return ctx.Err()
	case <-c.done:
		return errors.New("codex app-server stopped")
	}
}

func (c *Codex) removePending(key string) {
	c.pendingMu.Lock()
	delete(c.pending, key)
	c.pendingMu.Unlock()
}

func (c *Codex) readLoop() {
	for {
		_, payload, err := c.conn.Read(context.Background())
		if err != nil {
			c.ready.Store(false)
			c.failAll(fmt.Errorf("codex app-server connection closed: %w", err))
			c.closeOnce.Do(func() { close(c.done) })
			return
		}
		var msg envelope
		if err := json.Unmarshal(payload, &msg); err != nil {
			log.Printf("invalid codex message: %v", err)
			continue
		}
		if len(msg.ID) > 0 && msg.Method == "" {
			key := strings.Trim(string(msg.ID), `"`)
			c.pendingMu.Lock()
			ch := c.pending[key]
			delete(c.pending, key)
			c.pendingMu.Unlock()
			if ch != nil {
				if msg.Error != nil {
					ch <- rpcResponse{err: fmt.Errorf("%s (%d)", msg.Error.Message, msg.Error.Code)}
				} else {
					ch <- rpcResponse{result: msg.Result}
				}
			}
			continue
		}
		if len(msg.ID) > 0 && msg.Method != "" {
			// This local-only bridge deliberately does not approve privilege or elicitation requests.
			_ = c.write(map[string]any{"id": json.RawMessage(msg.ID), "error": map[string]any{"code": -32601, "message": "Interactive server requests are not supported by this web bridge"}})
			continue
		}
		if msg.Method != "" {
			c.handleNotification(msg.Method, msg.Params)
		}
	}
}

func (c *Codex) handleNotification(method string, raw json.RawMessage) {
	c.hub.broadcast(map[string]any{"type": "notification", "method": method, "params": json.RawMessage(raw)})
	var base struct {
		ThreadID string `json:"threadId"`
		TurnID   string `json:"turnId"`
	}
	_ = json.Unmarshal(raw, &base)
	if base.ThreadID == "" {
		return
	}
	switch method {
	case "item/agentMessage/delta":
		var p struct {
			Delta string `json:"delta"`
		}
		_ = json.Unmarshal(raw, &p)
		c.emit(base.ThreadID, streamEvent{"delta", map[string]string{"text": p.Delta}})
	case "item/started":
		var p struct {
			Item struct{ Type, Command, Query, Tool, Server string } `json:"item"`
		}
		_ = json.Unmarshal(raw, &p)
		label := activityLabel(p.Item.Type, p.Item.Command, p.Item.Query, p.Item.Tool, p.Item.Server)
		if label != "" {
			c.emit(base.ThreadID, streamEvent{"activity", map[string]string{"label": label}})
		}
	case "turn/completed":
		var p struct {
			Turn struct {
				Status string `json:"status"`
				Error  any    `json:"error"`
			} `json:"turn"`
		}
		_ = json.Unmarshal(raw, &p)
		if p.Turn.Status == "failed" {
			b, _ := json.Marshal(p.Turn.Error)
			c.emit(base.ThreadID, streamEvent{"error", map[string]string{"message": "Codex turn failed: " + string(b)}})
		}
		c.emit(base.ThreadID, streamEvent{"done", map[string]string{"status": p.Turn.Status}})
	case "error":
		var p struct {
			WillRetry bool `json:"willRetry"`
			Error     struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(raw, &p)
		if !p.WillRetry {
			c.emit(base.ThreadID, streamEvent{"error", map[string]string{"message": firstNonEmpty(p.Error.Message, "Codex reported an error")}})
		}
	}
}

func activityLabel(kind, command, query, tool, server string) string {
	switch kind {
	case "commandExecution":
		return "Running " + truncate(command, 72)
	case "fileChange":
		return "Updating workspace files"
	case "webSearch":
		return "Searching for " + truncate(query, 64)
	case "mcpToolCall":
		return "Using " + firstNonEmpty(server+" / "+tool, "a connected tool")
	case "dynamicToolCall":
		return "Using " + firstNonEmpty(tool, "a tool")
	case "reasoning":
		return "Working through the request"
	case "imageView":
		return "Inspecting an image"
	}
	return ""
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" && strings.TrimSpace(v) != "/" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func (c *Codex) emit(threadID string, event streamEvent) {
	c.streamsMu.RLock()
	ch := c.streams[threadID]
	c.streamsMu.RUnlock()
	if ch == nil {
		return
	}
	select {
	case ch <- event:
	default:
		log.Printf("dropping event for slow client on thread %s", threadID)
	}
}

func (c *Codex) failAll(err error) {
	c.pendingMu.Lock()
	for key, ch := range c.pending {
		ch <- rpcResponse{err: err}
		delete(c.pending, key)
	}
	c.pendingMu.Unlock()
	c.streamsMu.RLock()
	for _, ch := range c.streams {
		select {
		case ch <- streamEvent{"error", map[string]string{"message": err.Error()}}:
		default:
		}
	}
	c.streamsMu.RUnlock()
}

type server struct {
	codex            *Codex
	workspace        string
	model            string
	bootstrapThreads []string
}

type browserCommand struct {
	Type     string `json:"type"`
	ThreadID string `json:"threadId"`
}
type chatRequest struct {
	Message  string `json:"message"`
	ThreadID string `json:"threadId"`
}
type interruptRequest struct {
	ThreadID string `json:"threadId"`
	TurnID   string `json:"turnId"`
}

type threadSummary struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Preview   string `json:"preview"`
	UpdatedAt int64  `json:"updatedAt"`
	Status    any    `json:"status"`
}

type historyMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	state := "offline"
	if s.codex.ready.Load() {
		state = "ready"
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"codex": state, "workspace": s.workspace, "appServer": s.codex.endpoint})
}

func (s *server) websocket(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		log.Printf("websocket accept: %v", err)
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer conn.CloseNow()

	events := s.codex.hub.subscribe()
	defer s.codex.hub.unsubscribe(events)
	writeErr := make(chan error, 1)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case payload := <-events:
				writeCtx, writeCancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(writeCtx, websocket.MessageText, payload)
				writeCancel()
				if err != nil {
					select {
					case writeErr <- err:
					default:
					}
					cancel()
					return
				}
			}
		}
	}()

	connected, _ := json.Marshal(map[string]string{"type": "connected"})
	select {
	case events <- connected:
	default:
	}
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var command browserCommand
		if json.Unmarshal(data, &command) != nil {
			continue
		}
		if command.Type == "subscribe" && command.ThreadID != "" {
			subscribeCtx, subscribeCancel := context.WithTimeout(ctx, 15*time.Second)
			_, err := s.ensureThread(subscribeCtx, command.ThreadID)
			subscribeCancel()
			if err != nil {
				s.codex.hub.broadcast(map[string]any{"type": "subscriptionError", "threadId": command.ThreadID, "message": err.Error()})
			}
		}
		select {
		case <-writeErr:
			return
		default:
		}
	}
}

func (s *server) threads(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.codex.ready.Load() {
		http.Error(w, "codex app-server is unavailable", http.StatusServiceUnavailable)
		return
	}

	threadID := strings.TrimPrefix(r.URL.Path, "/api/threads/")
	if r.URL.Path != "/api/threads" && r.URL.Path != "/api/threads/" && threadID != "" {
		s.threadHistory(w, r, threadID)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	var result struct {
		Data []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			Preview   string `json:"preview"`
			UpdatedAt int64  `json:"updatedAt"`
			Status    any    `json:"status"`
		} `json:"data"`
	}
	err := s.codex.call(ctx, "thread/list", map[string]any{
		"cwd":           s.workspace,
		"limit":         40,
		"sortKey":       "updated_at",
		"sortDirection": "desc",
	}, &result)
	if err != nil {
		http.Error(w, "list threads: "+err.Error(), http.StatusBadGateway)
		return
	}

	threads := make([]threadSummary, 0, len(result.Data))
	seen := make(map[string]bool, len(result.Data))
	for _, item := range result.Data {
		title := strings.TrimSpace(item.Name)
		if title == "" {
			title = truncate(firstNonEmpty(item.Preview, "Untitled conversation"), 58)
		}
		threads = append(threads, threadSummary{ID: item.ID, Title: title, Preview: item.Preview, UpdatedAt: item.UpdatedAt, Status: item.Status})
		seen[item.ID] = true
	}
	for index := len(s.bootstrapThreads) - 1; index >= 0; index-- {
		id := s.bootstrapThreads[index]
		if seen[id] {
			continue
		}
		var pinned struct {
			Thread struct {
				ID        string `json:"id"`
				Name      string `json:"name"`
				Preview   string `json:"preview"`
				UpdatedAt int64  `json:"updatedAt"`
				Status    any    `json:"status"`
			} `json:"thread"`
		}
		if err := s.codex.call(ctx, "thread/read", map[string]any{"threadId": id, "includeTurns": false}, &pinned); err != nil {
			log.Printf("read bootstrap thread %s: %v", id, err)
			continue
		}
		title := strings.TrimSpace(pinned.Thread.Name)
		if title == "" {
			title = truncate(firstNonEmpty(pinned.Thread.Preview, "Bootstrap conversation"), 58)
		}
		threads = append([]threadSummary{{ID: pinned.Thread.ID, Title: title, Preview: pinned.Thread.Preview, UpdatedAt: pinned.Thread.UpdatedAt, Status: pinned.Thread.Status}}, threads...)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"threads": threads})
}

func (s *server) threadHistory(w http.ResponseWriter, r *http.Request, threadID string) {
	if len(threadID) > 128 || strings.ContainsAny(threadID, `/\\`) {
		http.Error(w, "invalid thread id", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	var result struct {
		Thread struct {
			ID    string `json:"id"`
			Name  string `json:"name"`
			Turns []struct {
				Items []json.RawMessage `json:"items"`
			} `json:"turns"`
		} `json:"thread"`
	}
	if err := s.codex.call(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, &result); err != nil {
		http.Error(w, "read thread: "+err.Error(), http.StatusBadGateway)
		return
	}

	messages := make([]historyMessage, 0)
	for _, turn := range result.Thread.Turns {
		for _, raw := range turn.Items {
			var item struct {
				Type    string `json:"type"`
				Text    string `json:"text"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			}
			if json.Unmarshal(raw, &item) != nil {
				continue
			}
			switch item.Type {
			case "userMessage":
				parts := make([]string, 0, len(item.Content))
				for _, input := range item.Content {
					if input.Type == "text" && strings.TrimSpace(input.Text) != "" {
						parts = append(parts, input.Text)
					}
				}
				appendHistory(&messages, "user", strings.Join(parts, "\n"))
			case "agentMessage":
				appendHistory(&messages, "assistant", item.Text)
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"threadId": result.Thread.ID, "title": result.Thread.Name, "messages": messages})
}

func appendHistory(messages *[]historyMessage, role, text string) {
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	items := *messages
	if len(items) > 0 && items[len(items)-1].Role == role {
		items[len(items)-1].Text += "\n\n" + text
		*messages = items
		return
	}
	*messages = append(items, historyMessage{Role: role, Text: text})
}

func (s *server) chat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req chatRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256*1024)).Decode(&req); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.Message == "" {
		http.Error(w, "message is required", http.StatusBadRequest)
		return
	}
	if !s.codex.ready.Load() {
		http.Error(w, "codex app-server is unavailable", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	threadID, err := s.ensureThread(ctx, req.ThreadID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	events := make(chan streamEvent, 1024)
	s.codex.streamsMu.Lock()
	if _, busy := s.codex.streams[threadID]; busy {
		s.codex.streamsMu.Unlock()
		http.Error(w, "this thread already has an active turn", http.StatusConflict)
		return
	}
	s.codex.streams[threadID] = events
	s.codex.streamsMu.Unlock()
	defer func() { s.codex.streamsMu.Lock(); delete(s.codex.streams, threadID); s.codex.streamsMu.Unlock() }()

	params := map[string]any{"threadId": threadID, "input": []map[string]any{{"type": "text", "text": req.Message}}}
	if s.model != "" {
		params["model"] = s.model
	}
	var started struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	callCtx, callCancel := context.WithTimeout(ctx, 30*time.Second)
	err = s.codex.call(callCtx, "turn/start", params, &started)
	callCancel()
	if err != nil {
		http.Error(w, "start turn: "+err.Error(), http.StatusBadGateway)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	sse(w, "ready", map[string]string{"threadId": threadID, "turnId": started.Turn.ID})
	flusher.Flush()

	for {
		select {
		case event := <-events:
			sse(w, event.name, event.data)
			flusher.Flush()
			if event.name == "done" || event.name == "error" {
				return
			}
		case <-ctx.Done():
			interruptCtx, interruptCancel := context.WithTimeout(context.Background(), 3*time.Second)
			_ = s.codex.call(interruptCtx, "turn/interrupt", map[string]string{"threadId": threadID, "turnId": started.Turn.ID}, nil)
			interruptCancel()
			return
		case <-time.After(25 * time.Second):
			_, _ = io.WriteString(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

func (s *server) ensureThread(ctx context.Context, requested string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested != "" {
		s.codex.knownMu.Lock()
		known := s.codex.known[requested]
		s.codex.knownMu.Unlock()
		if !known {
			var resumed map[string]any
			if err := s.codex.call(ctx, "thread/resume", map[string]any{"threadId": requested, "cwd": s.workspace, "sandbox": "workspace-write", "approvalPolicy": "never"}, &resumed); err != nil {
				return "", fmt.Errorf("resume thread: %w", err)
			}
			s.codex.knownMu.Lock()
			s.codex.known[requested] = true
			s.codex.knownMu.Unlock()
		}
		return requested, nil
	}
	params := map[string]any{"cwd": s.workspace, "runtimeWorkspaceRoots": []string{s.workspace}, "sandbox": "workspace-write", "approvalPolicy": "never", "ephemeral": false}
	if s.model != "" {
		params["model"] = s.model
	}
	var started struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if err := s.codex.call(ctx, "thread/start", params, &started); err != nil {
		return "", fmt.Errorf("start thread: %w", err)
	}
	if started.Thread.ID == "" {
		return "", errors.New("codex returned an empty thread id")
	}
	s.codex.knownMu.Lock()
	s.codex.known[started.Thread.ID] = true
	s.codex.knownMu.Unlock()
	return started.Thread.ID, nil
}

func (s *server) interrupt(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req interruptRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ThreadID == "" || req.TurnID == "" {
		http.Error(w, "threadId and turnId are required", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.codex.call(ctx, "turn/interrupt", map[string]string{"threadId": req.ThreadID, "turnId": req.TurnID}, nil); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func sse(w io.Writer, event string, data any) {
	b, _ := json.Marshal(data)
	_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
}

func main() {
	workspace := env("CODEX_WORKSPACE", "")
	if workspace == "" {
		var err error
		workspace, err = os.Getwd()
		if err != nil {
			log.Fatal(err)
		}
		if filepath.Base(workspace) == "server" {
			workspace = filepath.Dir(workspace)
		}
	}
	absWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		log.Fatal(err)
	}
	info, err := os.Stat(absWorkspace)
	if err != nil || !info.IsDir() {
		log.Fatalf("invalid CODEX_WORKSPACE %q", absWorkspace)
	}

	appServerURL := env("CODEX_APP_SERVER_URL", "ws://127.0.0.1:40002")
	if !strings.HasPrefix(appServerURL, "ws://") {
		log.Fatalf("CODEX_APP_SERVER_URL must be a ws:// endpoint, got %q", appServerURL)
	}
	codex, err := startCodex(env("CODEX_BIN", "codex"), appServerURL)
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		codex.ready.Store(false)
		_ = codex.conn.Close(websocket.StatusNormalClosure, "web bridge stopped")
		if codex.cmd != nil && codex.cmd.Process != nil {
			_ = codex.cmd.Process.Kill()
		}
	}()
	bootstrapThreads := splitNonEmpty(env("CODEX_BOOTSTRAP_THREADS", ""))
	s := &server{codex: codex, workspace: absWorkspace, model: os.Getenv("CODEX_MODEL"), bootstrapThreads: bootstrapThreads}
	for _, threadID := range bootstrapThreads {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		_, resumeErr := s.ensureThread(ctx, threadID)
		cancel()
		if resumeErr != nil {
			log.Printf("bootstrap thread %s could not be resumed: %v", threadID, resumeErr)
			continue
		}
		log.Printf("resumed bootstrap thread: %s", threadID)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", s.health)
	mux.HandleFunc("/api/ws", s.websocket)
	mux.HandleFunc("/api/threads", s.threads)
	mux.HandleFunc("/api/threads/", s.threads)
	mux.HandleFunc("/api/chat", s.chat)
	mux.HandleFunc("/api/interrupt", s.interrupt)
	dist := http.Dir(filepath.Join(absWorkspace, "dist"))
	mux.Handle("/", spaHandler(dist))

	address := "0.0.0.0:" + env("PORT", "40001")
	log.Printf("Codex web bridge listening at http://%s", address)
	log.Printf("shared Codex app-server listening at %s", appServerURL)
	log.Printf("remote TUI: codex resume --remote %s <SESSION_ID>", appServerURL)
	log.Printf("workspace: %s", absWorkspace)
	if err := http.ListenAndServe(address, securityHeaders(mux)); err != nil {
		log.Fatal(err)
	}
}

func spaHandler(root http.FileSystem) http.Handler {
	files := http.FileServer(root)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(filepath.Clean(r.URL.Path), "/")
		if path == "." {
			path = "index.html"
		}
		if f, err := root.Open(path); err == nil {
			_ = f.Close()
			files.ServeHTTP(w, r)
			return
		}
		r.URL.Path = "/"
		files.ServeHTTP(w, r)
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'")
		next.ServeHTTP(w, r)
	})
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func splitNonEmpty(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}
