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
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/fsnotify/fsnotify"
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

type activeTurn struct {
	TurnID      string
	ActiveFlags []string
}

type threadRuntimeStatus struct {
	Type        string   `json:"type"`
	ActiveFlags []string `json:"activeFlags,omitempty"`
}

type commandApproval struct {
	ID                 string          `json:"id"`
	Kind               string          `json:"kind"`
	ThreadID           string          `json:"threadId"`
	TurnID             string          `json:"turnId,omitempty"`
	ItemID             string          `json:"itemId,omitempty"`
	Command            string          `json:"command"`
	CWD                string          `json:"cwd,omitempty"`
	Environment        string          `json:"environment"`
	Reason             string          `json:"reason,omitempty"`
	ProposedExecPrefix []string        `json:"proposedExecPrefix,omitempty"`
	StartedAtMs        int64           `json:"startedAtMs"`
	Submitted          bool            `json:"submitted,omitempty"`
	GrantRoot          string          `json:"grantRoot,omitempty"`
	Permissions        any             `json:"permissions,omitempty"`
	Questions          []inputQuestion `json:"questions,omitempty"`
	ServerName         string          `json:"serverName,omitempty"`
	Message            string          `json:"message,omitempty"`
}

type inputOption struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

type inputQuestion struct {
	ID       string        `json:"id"`
	Header   string        `json:"header,omitempty"`
	Question string        `json:"question"`
	IsOther  bool          `json:"isOther,omitempty"`
	IsSecret bool          `json:"isSecret,omitempty"`
	Options  []inputOption `json:"options,omitempty"`
}

type pendingApproval struct {
	Request         commandApproval
	Method          string
	RPCID           json.RawMessage
	SubmittedChoice string
}

type runtimeSnapshot struct {
	Type        string            `json:"type"`
	ThreadID    string            `json:"threadId"`
	Working     bool              `json:"working"`
	TurnID      string            `json:"turnId,omitempty"`
	ActiveFlags []string          `json:"activeFlags,omitempty"`
	Approvals   []commandApproval `json:"approvals"`
}

type authSnapshot struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	RequiresOpenAIAuth bool   `json:"requiresOpenaiAuth"`
	AuthMode           string `json:"authMode,omitempty"`
	PlanType           string `json:"planType,omitempty"`
	LoginID            string `json:"loginId,omitempty"`
	VerificationURL    string `json:"verificationUrl,omitempty"`
	UserCode           string `json:"userCode,omitempty"`
	Message            string `json:"message,omitempty"`
}

type accountInfo struct {
	Type     string `json:"type"`
	PlanType string `json:"planType,omitempty"`
}

type accountReadResult struct {
	Account            *accountInfo `json:"account"`
	RequiresOpenAIAuth bool         `json:"requiresOpenaiAuth"`
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
	richMu    sync.RWMutex
	rich      map[string]map[string][]historyMessage
	stateMu   sync.RWMutex
	active    map[string]activeTurn
	approvals map[string]pendingApproval
	authMu    sync.RWMutex
	auth      authSnapshot
	hub       *socketHub
	nextID    atomic.Int64
	nextUIID  atomic.Int64
	ready     atomic.Bool
	authCheck atomic.Bool
	authLogin atomic.Bool
	authSync  atomic.Bool
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
		c := newCodex(existingConn, endpoint)
		go c.readLoop()
		if err := c.initialize(); err != nil {
			c.conn.CloseNow()
			return nil, fmt.Errorf("initialize existing codex app-server: %w", err)
		}
		go c.watchAuthChanges(bin)
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

	c := newCodex(nil, endpoint)
	c.cmd = cmd
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
	go c.watchAuthChanges(bin)
	log.Printf("started shared Codex app-server at %s", endpoint)
	return c, nil
}

func newCodex(conn *websocket.Conn, endpoint string) *Codex {
	return &Codex{
		conn:      conn,
		endpoint:  endpoint,
		pending:   make(map[string]chan rpcResponse),
		streams:   make(map[string]chan streamEvent),
		known:     make(map[string]bool),
		rich:      make(map[string]map[string][]historyMessage),
		active:    make(map[string]activeTurn),
		approvals: make(map[string]pendingApproval),
		auth:      authSnapshot{Type: "auth/snapshot", Status: "checking"},
		hub:       newSocketHub(),
		done:      make(chan struct{}),
	}
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
	go c.refreshAuth(true)
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
			if !strings.HasPrefix(method, "account/") && isAuthError(got.err) {
				go c.refreshAuth(true)
			}
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

func authStateFromAccount(result accountReadResult) authSnapshot {
	state := authSnapshot{
		Type:               "auth/snapshot",
		Status:             "authenticated",
		RequiresOpenAIAuth: result.RequiresOpenAIAuth,
	}
	if result.Account != nil {
		state.AuthMode = result.Account.Type
		state.PlanType = result.Account.PlanType
		return state
	}
	if result.RequiresOpenAIAuth {
		state.Status = "required"
		state.Message = "Sign in to OpenAI to continue using Codex."
	}
	return state
}

func (c *Codex) authState() authSnapshot {
	c.authMu.RLock()
	state := c.auth
	c.authMu.RUnlock()
	if state.Type == "" {
		state.Type = "auth/snapshot"
	}
	if state.Status == "" {
		state.Status = "checking"
	}
	return state
}

func (c *Codex) setAuthState(state authSnapshot) {
	state.Type = "auth/snapshot"
	c.authMu.Lock()
	changed := c.auth != state
	c.auth = state
	c.authMu.Unlock()
	if changed && c.hub != nil {
		c.hub.broadcast(state)
	}
}

func (c *Codex) refreshAuth(refreshToken bool) {
	if !c.authCheck.CompareAndSwap(false, true) {
		return
	}
	defer c.authCheck.Store(false)

	current := c.authState()
	// Auth failures can keep arriving from work that was already in flight when
	// device login began. Keep the issued code stable until app-server reports
	// account/login/completed; that notification will move the state out of
	// pending before asking us to verify the new account.
	if current.Status == "pending" || current.Status == "starting" || current.Status == "syncing" || current.Status == "completing" || current.Status == "error" {
		return
	}
	current.Status = "checking"
	current.Message = ""
	c.setAuthState(current)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	var result accountReadResult
	err := c.call(ctx, "account/read", map[string]bool{"refreshToken": refreshToken}, &result)
	cancel()
	if err != nil {
		if isAuthError(err) {
			c.setAuthState(authSnapshot{
				Status:             "required",
				RequiresOpenAIAuth: true,
				Message:            "Your Codex login is missing or expired.",
			})
			if loginErr := c.startDeviceLogin(context.Background()); loginErr != nil {
				log.Printf("start Codex device login after auth failure: %v", loginErr)
			}
			return
		}
		current = c.authState()
		current.Status = "error"
		current.Message = "Could not check Codex authentication: " + err.Error()
		c.setAuthState(current)
		return
	}

	state := authStateFromAccount(result)
	c.setAuthState(state)
	if state.Status == "required" {
		if err := c.startDeviceLogin(context.Background()); err != nil {
			log.Printf("start Codex device login: %v", err)
		}
	}
}

func (c *Codex) confirmCompletedLogin() {
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-c.done:
		return
	}

	if c.authState().Status != "completing" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	var result accountReadResult
	err := c.call(ctx, "account/read", map[string]bool{"refreshToken": true}, &result)
	cancel()
	// account/updated may have confirmed the login while account/read was in
	// flight. Never overwrite that authoritative notification.
	if c.authState().Status != "completing" {
		return
	}
	if err == nil {
		state := authStateFromAccount(result)
		if state.Status == "authenticated" {
			c.setAuthState(state)
			return
		}
	}

	message := "Sign-in finished, but Codex did not confirm the account. Request a new code and try again."
	if err != nil {
		message = "Sign-in finished, but Codex could not confirm the account: " + err.Error()
	}
	c.setAuthState(authSnapshot{
		Status:             "error",
		RequiresOpenAIAuth: true,
		Message:            message,
	})
}

func (c *Codex) startDeviceLogin(parent context.Context) error {
	current := c.authState()
	if current.Status == "authenticated" || current.Status == "pending" || current.Status == "starting" {
		return nil
	}
	if !c.authLogin.CompareAndSwap(false, true) {
		return nil
	}
	defer c.authLogin.Store(false)
	c.setAuthState(authSnapshot{
		Status:             "starting",
		RequiresOpenAIAuth: true,
		Message:            "Requesting a one-time OpenAI sign-in code…",
	})

	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	var result struct {
		Type            string `json:"type"`
		LoginID         string `json:"loginId"`
		VerificationURL string `json:"verificationUrl"`
		UserCode        string `json:"userCode"`
	}
	if err := c.call(ctx, "account/login/start", map[string]string{"type": "chatgptDeviceCode"}, &result); err != nil {
		c.setAuthState(authSnapshot{
			Status:             "error",
			RequiresOpenAIAuth: true,
			Message:            "Could not start OpenAI device sign-in: " + err.Error(),
		})
		return err
	}
	if result.LoginID == "" || result.VerificationURL == "" || result.UserCode == "" {
		err := errors.New("Codex returned an incomplete device sign-in response")
		c.setAuthState(authSnapshot{Status: "error", RequiresOpenAIAuth: true, Message: err.Error()})
		return err
	}
	c.setAuthState(authSnapshot{
		Status:             "pending",
		RequiresOpenAIAuth: true,
		LoginID:            result.LoginID,
		VerificationURL:    result.VerificationURL,
		UserCode:           result.UserCode,
		Message:            "Open the OpenAI sign-in page and enter the one-time code.",
	})
	return nil
}

func codexAuthPath() (string, error) {
	codexHome := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if codexHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		codexHome = filepath.Join(home, ".codex")
	}
	if !filepath.IsAbs(codexHome) {
		return "", errors.New("CODEX_HOME must be an absolute path")
	}
	return filepath.Join(filepath.Clean(codexHome), "auth.json"), nil
}

func (c *Codex) watchAuthChanges(bin string) {
	authPath, err := codexAuthPath()
	if err != nil {
		log.Printf("Codex auth watcher disabled: %v", err)
		return
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("Codex auth watcher disabled: %v", err)
		return
	}
	defer watcher.Close()
	if err := watcher.Add(filepath.Dir(authPath)); err != nil {
		log.Printf("Codex auth watcher could not watch %s: %v", filepath.Dir(authPath), err)
		return
	}
	authSignalPath := filepath.Join(filepath.Dir(authPath), ".auth-changed")

	var timer *time.Timer
	schedule := func(delay time.Duration) {
		if timer != nil {
			timer.Stop()
		}
		timer = time.AfterFunc(delay, func() { c.syncExternalAuth(bin) })
	}
	// Reconcile once after initialization so a logout that occurred while the
	// bridge was stopped is still reflected by a reused app-server process.
	schedule(750 * time.Millisecond)

	for {
		select {
		case <-c.done:
			if timer != nil {
				timer.Stop()
			}
			return
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			changedPath := filepath.Clean(event.Name)
			if (changedPath == authPath || changedPath == authSignalPath) && event.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Remove|fsnotify.Rename|fsnotify.Chmod) != 0 {
				schedule(200 * time.Millisecond)
			}
		case watchErr, ok := <-watcher.Errors:
			if !ok {
				return
			}
			log.Printf("Codex auth watcher: %v", watchErr)
		}
	}
}

func (c *Codex) syncExternalAuth(bin string) {
	if !c.ready.Load() || !c.authSync.CompareAndSwap(false, true) {
		return
	}
	defer c.authSync.Store(false)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	output, err := exec.CommandContext(ctx, bin, "login", "status").CombinedOutput()
	cancel()
	if err == nil {
		state := c.authState()
		if state.Status == "required" || state.Status == "error" {
			state.Status = "checking"
			state.Message = "Detected a Codex login from another process. Confirming the shared account…"
			c.setAuthState(state)
			go c.refreshAuth(true)
		}
		return
	}
	if !strings.Contains(strings.ToLower(string(output)), "not logged in") {
		log.Printf("could not verify external Codex auth state: %v", err)
		return
	}

	state := c.authState()
	if state.Status == "required" || state.Status == "pending" || state.Status == "starting" || state.Status == "syncing" || state.Status == "completing" || state.Status == "error" {
		return
	}
	c.setAuthState(authSnapshot{
		Status:             "syncing",
		RequiresOpenAIAuth: true,
		Message:            "Codex logout detected. Synchronizing the shared app-server…",
	})

	logoutCtx, logoutCancel := context.WithTimeout(context.Background(), 10*time.Second)
	err = c.call(logoutCtx, "account/logout", map[string]any{}, nil)
	logoutCancel()
	if err != nil {
		c.setAuthState(authSnapshot{
			Status:             "error",
			RequiresOpenAIAuth: true,
			Message:            "Detected a Codex logout but could not synchronize app-server: " + err.Error(),
		})
		return
	}
	c.setAuthState(authSnapshot{
		Status:             "required",
		RequiresOpenAIAuth: true,
		Message:            "Codex was logged out from another process.",
	})
	if err := c.startDeviceLogin(context.Background()); err != nil {
		log.Printf("start Codex device login after external logout: %v", err)
	}
}

func isAuthError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	markers := []string{
		"401",
		"unauthorized",
		"authentication required",
		"not logged in",
		"refresh_token_expired",
		"refresh token expired",
		"login required",
	}
	for _, marker := range markers {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
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
			if !c.handleServerRequest(msg.ID, msg.Method, msg.Params) {
				_ = c.write(map[string]any{"id": json.RawMessage(msg.ID), "error": map[string]any{"code": -32601, "message": "This interactive server request is not supported by the web bridge"}})
			}
			continue
		}
		if msg.Method != "" {
			c.handleNotification(msg.Method, msg.Params)
		}
	}
}

func (c *Codex) handleServerRequest(rpcID json.RawMessage, method string, raw json.RawMessage) bool {
	approval := commandApproval{
		ID:          "approval-" + strconv.FormatInt(c.nextUIID.Add(1), 10),
		Kind:        "command",
		Environment: "local",
		StartedAtMs: time.Now().UnixMilli(),
	}
	switch method {
	case "item/commandExecution/requestApproval":
		var params struct {
			ThreadID                    string          `json:"threadId"`
			TurnID                      string          `json:"turnId"`
			ItemID                      string          `json:"itemId"`
			Command                     string          `json:"command"`
			CWD                         string          `json:"cwd"`
			EnvironmentID               string          `json:"environmentId"`
			Reason                      string          `json:"reason"`
			ProposedExecpolicyAmendment json.RawMessage `json:"proposedExecpolicyAmendment"`
			StartedAtMs                 int64           `json:"startedAtMs"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ThreadID == "" {
			return false
		}
		approval.ThreadID = params.ThreadID
		approval.TurnID = params.TurnID
		approval.ItemID = params.ItemID
		approval.Command = params.Command
		approval.CWD = params.CWD
		approval.Environment = firstNonEmpty(params.EnvironmentID, "local")
		approval.Reason = params.Reason
		approval.ProposedExecPrefix = execPolicyPrefix(params.ProposedExecpolicyAmendment)
		if params.StartedAtMs != 0 {
			approval.StartedAtMs = params.StartedAtMs
		}
	case "item/fileChange/requestApproval":
		var params struct {
			ThreadID    string `json:"threadId"`
			TurnID      string `json:"turnId"`
			ItemID      string `json:"itemId"`
			StartedAtMs int64  `json:"startedAtMs"`
			Reason      string `json:"reason"`
			GrantRoot   string `json:"grantRoot"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ThreadID == "" {
			return false
		}
		approval.Kind = "fileChange"
		approval.ThreadID = params.ThreadID
		approval.TurnID = params.TurnID
		approval.ItemID = params.ItemID
		approval.Reason = params.Reason
		approval.GrantRoot = params.GrantRoot
		if params.StartedAtMs != 0 {
			approval.StartedAtMs = params.StartedAtMs
		}
	case "item/permissions/requestApproval":
		var params struct {
			ThreadID      string          `json:"threadId"`
			TurnID        string          `json:"turnId"`
			ItemID        string          `json:"itemId"`
			EnvironmentID string          `json:"environmentId"`
			StartedAtMs   int64           `json:"startedAtMs"`
			CWD           string          `json:"cwd"`
			Reason        string          `json:"reason"`
			Permissions   json.RawMessage `json:"permissions"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ThreadID == "" || len(params.Permissions) == 0 {
			return false
		}
		var permissions any
		if json.Unmarshal(params.Permissions, &permissions) != nil {
			return false
		}
		approval.Kind = "permissions"
		approval.ThreadID = params.ThreadID
		approval.TurnID = params.TurnID
		approval.ItemID = params.ItemID
		approval.Environment = firstNonEmpty(params.EnvironmentID, "local")
		approval.CWD = params.CWD
		approval.Reason = params.Reason
		approval.Permissions = permissions
		if params.StartedAtMs != 0 {
			approval.StartedAtMs = params.StartedAtMs
		}
	case "item/tool/requestUserInput":
		var params struct {
			ThreadID  string          `json:"threadId"`
			TurnID    string          `json:"turnId"`
			ItemID    string          `json:"itemId"`
			Questions []inputQuestion `json:"questions"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ThreadID == "" || len(params.Questions) == 0 {
			return false
		}
		approval.Kind = "userInput"
		approval.ThreadID = params.ThreadID
		approval.TurnID = params.TurnID
		approval.ItemID = params.ItemID
		approval.Questions = params.Questions
	case "mcpServer/elicitation/request":
		var params struct {
			ThreadID   string `json:"threadId"`
			TurnID     string `json:"turnId"`
			ServerName string `json:"serverName"`
			Message    string `json:"message"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ThreadID == "" {
			return false
		}
		approval.Kind = "mcpElicitation"
		approval.ThreadID = params.ThreadID
		approval.TurnID = params.TurnID
		approval.ServerName = params.ServerName
		approval.Message = params.Message
	case "execCommandApproval":
		var params struct {
			ConversationID string   `json:"conversationId"`
			Command        []string `json:"command"`
			CWD            string   `json:"cwd"`
			Reason         string   `json:"reason"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ConversationID == "" {
			return false
		}
		approval.ThreadID = params.ConversationID
		approval.Kind = "command"
		approval.Command = strings.Join(params.Command, " ")
		approval.CWD = params.CWD
		approval.Reason = params.Reason
	default:
		return false
	}

	c.stateMu.Lock()
	if c.approvals == nil {
		c.approvals = make(map[string]pendingApproval)
	}
	c.approvals[approval.ID] = pendingApproval{Request: approval, Method: method, RPCID: append(json.RawMessage(nil), rpcID...)}
	if c.active == nil {
		c.active = make(map[string]activeTurn)
	}
	active := c.active[approval.ThreadID]
	if approval.TurnID != "" {
		active.TurnID = approval.TurnID
	}
	active.ActiveFlags = addString(active.ActiveFlags, "waitingOnApproval")
	c.active[approval.ThreadID] = active
	c.stateMu.Unlock()
	log.Printf("Codex approval request received: approval_id=%s request_id=%s thread_id=%s method=%s", approval.ID, rpcIDKey(rpcID), approval.ThreadID, method)
	c.broadcastRuntime(approval.ThreadID)
	return true
}

func execPolicyPrefix(raw json.RawMessage) []string {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var prefix []string
	if json.Unmarshal(raw, &prefix) == nil {
		return prefix
	}
	var amendment struct {
		Command []string `json:"command"`
	}
	if json.Unmarshal(raw, &amendment) == nil {
		return amendment.Command
	}
	return nil
}

func addString(items []string, value string) []string {
	for _, item := range items {
		if item == value {
			return items
		}
	}
	return append(items, value)
}

func removeString(items []string, value string) []string {
	result := make([]string, 0, len(items))
	for _, item := range items {
		if item != value {
			result = append(result, item)
		}
	}
	return result
}

func (c *Codex) resolveApproval(id, choice string, answers map[string][]string, content map[string]any) error {
	c.stateMu.Lock()
	pending, ok := c.approvals[id]
	if !ok {
		c.stateMu.Unlock()
		return errors.New("approval is no longer pending")
	}
	if pending.SubmittedChoice != "" {
		c.stateMu.Unlock()
		return errors.New("approval response is already being processed")
	}
	pending.SubmittedChoice = choice
	c.approvals[id] = pending
	c.stateMu.Unlock()

	result, err := approvalResponse(pending, choice, answers, content)
	if err != nil {
		c.stateMu.Lock()
		pending.SubmittedChoice = ""
		c.approvals[id] = pending
		c.stateMu.Unlock()
		return err
	}
	log.Printf("submitting Codex approval response: approval_id=%s request_id=%s thread_id=%s choice=%s", id, rpcIDKey(pending.RPCID), pending.Request.ThreadID, choice)
	if err := c.write(map[string]any{"id": pending.RPCID, "result": result}); err != nil {
		c.stateMu.Lock()
		pending.SubmittedChoice = ""
		c.approvals[id] = pending
		c.stateMu.Unlock()
		log.Printf("Codex approval response failed: approval_id=%s request_id=%s: %v", id, rpcIDKey(pending.RPCID), err)
		return err
	}

	// A successful websocket write only means that the response left this
	// process. Keep the approval pending until app-server broadcasts
	// serverRequest/resolved, which is also what dismisses it in remote TUIs.
	c.hub.broadcast(map[string]any{"type": "approval/submitted", "threadId": pending.Request.ThreadID, "approvalId": id, "decision": choice})
	c.broadcastRuntime(pending.Request.ThreadID)
	return nil
}

func rpcIDKey(id json.RawMessage) string {
	return strings.Trim(strings.TrimSpace(string(id)), `"`)
}

func (c *Codex) resolveApprovalFromNotification(raw json.RawMessage) {
	var params struct {
		ThreadID  string          `json:"threadId"`
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(raw, &params) != nil || len(params.RequestID) == 0 {
		return
	}

	requestKey := rpcIDKey(params.RequestID)
	if requestKey == "" {
		return
	}

	c.stateMu.Lock()
	resolvedID := ""
	threadID := ""
	for id, pending := range c.approvals {
		if rpcIDKey(pending.RPCID) != requestKey {
			continue
		}
		resolvedID = id
		threadID = pending.Request.ThreadID
		delete(c.approvals, id)
		break
	}
	if resolvedID == "" {
		c.stateMu.Unlock()
		log.Printf("Codex approval resolution did not match a browser approval: request_id=%s thread_id=%s", requestKey, params.ThreadID)
		return
	}
	if threadID == "" {
		threadID = params.ThreadID
	}
	active := c.active[threadID]
	stillWaiting := false
	for _, other := range c.approvals {
		if other.Request.ThreadID == threadID {
			stillWaiting = true
			break
		}
	}
	if !stillWaiting {
		active.ActiveFlags = removeString(active.ActiveFlags, "waitingOnApproval")
		c.active[threadID] = active
	}
	c.stateMu.Unlock()

	log.Printf("Codex approval resolved: approval_id=%s request_id=%s thread_id=%s", resolvedID, requestKey, threadID)
	c.hub.broadcast(map[string]any{"type": "approval/resolved", "threadId": threadID, "approvalId": resolvedID})
	c.broadcastRuntime(threadID)
}

func approvalResponse(pending pendingApproval, choice string, answers map[string][]string, content map[string]any) (map[string]any, error) {
	switch pending.Method {
	case "item/commandExecution/requestApproval":
		var decision any
		switch choice {
		case "accept":
			decision = "accept"
		case "always":
			if len(pending.Request.ProposedExecPrefix) > 0 {
				decision = map[string]any{"acceptWithExecpolicyAmendment": map[string]any{"execpolicy_amendment": pending.Request.ProposedExecPrefix}}
			} else {
				decision = "acceptForSession"
			}
		case "decline":
			decision = "decline"
		case "cancel":
			decision = "cancel"
		default:
			return nil, errors.New("invalid approval decision")
		}
		return map[string]any{"decision": decision}, nil
	case "item/fileChange/requestApproval":
		decisions := map[string]string{
			"accept":  "accept",
			"always":  "acceptForSession",
			"decline": "decline",
			"cancel":  "cancel",
		}
		decision, ok := decisions[choice]
		if !ok {
			return nil, errors.New("invalid file change approval decision")
		}
		return map[string]any{"decision": decision}, nil
	case "item/permissions/requestApproval":
		if choice != "accept" && choice != "always" && choice != "decline" && choice != "cancel" {
			return nil, errors.New("invalid permissions decision")
		}
		permissions := pending.Request.Permissions
		if choice == "decline" || choice == "cancel" {
			permissions = map[string]any{}
		}
		scope := "turn"
		if choice == "always" {
			scope = "session"
		}
		return map[string]any{"permissions": permissions, "scope": scope}, nil
	case "item/tool/requestUserInput":
		if len(answers) == 0 {
			return nil, errors.New("answers are required")
		}
		formatted := make(map[string]any, len(answers))
		for questionID, values := range answers {
			formatted[questionID] = map[string]any{"answers": values}
		}
		return map[string]any{"answers": formatted}, nil
	case "mcpServer/elicitation/request":
		actions := map[string]string{"accept": "accept", "decline": "decline", "cancel": "cancel"}
		action, ok := actions[choice]
		if !ok {
			return nil, errors.New("invalid MCP elicitation decision")
		}
		var responseContent any
		if choice == "accept" && len(content) > 0 {
			responseContent = content
		}
		return map[string]any{"action": action, "content": responseContent, "_meta": nil}, nil
	case "execCommandApproval":
		var decision any
		switch choice {
		case "accept":
			decision = "approved"
		case "always":
			decision = "approved_for_session"
		case "decline":
			decision = map[string]any{"denied": map[string]string{"rejection": "Command declined from the Web UX"}}
		case "cancel":
			decision = "abort"
		default:
			return nil, errors.New("invalid approval decision")
		}
		return map[string]any{"decision": decision}, nil
	default:
		return nil, errors.New("unsupported approval request")
	}
}

func (c *Codex) runtimeSnapshot(threadID string) runtimeSnapshot {
	c.stateMu.RLock()
	active, working := c.active[threadID]
	approvals := make([]commandApproval, 0)
	for _, pending := range c.approvals {
		if pending.Request.ThreadID == threadID {
			approval := pending.Request
			approval.Submitted = pending.SubmittedChoice != ""
			approvals = append(approvals, approval)
		}
	}
	c.stateMu.RUnlock()
	sort.Slice(approvals, func(i, j int) bool {
		if approvals[i].StartedAtMs == approvals[j].StartedAtMs {
			return approvals[i].ID < approvals[j].ID
		}
		return approvals[i].StartedAtMs < approvals[j].StartedAtMs
	})
	return runtimeSnapshot{Type: "runtime/snapshot", ThreadID: threadID, Working: working, TurnID: active.TurnID, ActiveFlags: append([]string(nil), active.ActiveFlags...), Approvals: approvals}
}

func (c *Codex) broadcastRuntime(threadID string) {
	if threadID != "" {
		c.hub.broadcast(c.runtimeSnapshot(threadID))
	}
}

func (c *Codex) setActiveTurn(threadID, turnID string, activeFlags []string) {
	if threadID == "" {
		return
	}
	c.stateMu.Lock()
	if c.active == nil {
		c.active = make(map[string]activeTurn)
	}
	current, exists := c.active[threadID]
	next := current
	if turnID != "" {
		next.TurnID = turnID
	}
	if activeFlags != nil {
		next.ActiveFlags = append([]string(nil), activeFlags...)
	}
	changed := !exists || current.TurnID != next.TurnID || strings.Join(current.ActiveFlags, "\x00") != strings.Join(next.ActiveFlags, "\x00")
	c.active[threadID] = next
	c.stateMu.Unlock()
	if changed {
		c.broadcastRuntime(threadID)
	}
}

func (c *Codex) clearActiveTurn(threadID, turnID string) {
	if threadID == "" {
		return
	}
	c.stateMu.Lock()
	current, exists := c.active[threadID]
	if exists && (turnID == "" || current.TurnID == "" || current.TurnID == turnID) {
		delete(c.active, threadID)
	}
	c.stateMu.Unlock()
	if exists {
		c.broadcastRuntime(threadID)
	}
}

func (c *Codex) applyThreadStatus(threadID string, status threadRuntimeStatus) {
	if status.Type == "active" {
		c.setActiveTurn(threadID, "", status.ActiveFlags)
		return
	}
	if status.Type == "idle" || status.Type == "systemError" {
		c.clearActiveTurn(threadID, "")
	}
}

func (c *Codex) reconcileRuntime(threadID string, status threadRuntimeStatus, turns []threadTurn) runtimeSnapshot {
	if status.Type == "active" {
		turnID := ""
		for index := len(turns) - 1; index >= 0; index-- {
			if turns[index].Status == "inProgress" {
				turnID = turns[index].ID
				break
			}
		}
		c.setActiveTurn(threadID, turnID, status.ActiveFlags)
	} else if status.Type == "idle" || status.Type == "systemError" {
		c.clearActiveTurn(threadID, "")
	}
	return c.runtimeSnapshot(threadID)
}

func (c *Codex) handleNotification(method string, raw json.RawMessage) {
	c.hub.broadcast(map[string]any{"type": "notification", "method": method, "params": json.RawMessage(raw)})
	if method == "serverRequest/resolved" {
		c.resolveApprovalFromNotification(raw)
		return
	}
	switch method {
	case "account/updated":
		var params struct {
			AuthMode *string `json:"authMode"`
			PlanType *string `json:"planType"`
		}
		if json.Unmarshal(raw, &params) == nil && params.AuthMode != nil && *params.AuthMode != "" {
			planType := ""
			if params.PlanType != nil {
				planType = *params.PlanType
			}
			c.setAuthState(authSnapshot{
				Status:             "authenticated",
				RequiresOpenAIAuth: *params.AuthMode != "bedrockApiKey",
				AuthMode:           *params.AuthMode,
				PlanType:           planType,
			})
		} else {
			go c.refreshAuth(false)
		}
	case "account/login/completed":
		var params struct {
			LoginID *string `json:"loginId"`
			Success bool    `json:"success"`
			Error   *string `json:"error"`
		}
		if json.Unmarshal(raw, &params) == nil {
			current := c.authState()
			if params.LoginID != nil && current.LoginID != "" && *params.LoginID != current.LoginID {
				break
			}
			// Notifications can be duplicated or arrive after account/updated.
			// Neither a late success nor a late failure may regress a confirmed
			// account or restart completion confirmation.
			if current.Status == "authenticated" || current.Status == "completing" {
				break
			}
			if params.Success {
				current.Status = "completing"
				current.Message = "Sign-in completed. Waiting for Codex account confirmation…"
				current.VerificationURL = ""
				current.UserCode = ""
				c.setAuthState(current)
				go c.confirmCompletedLogin()
			} else {
				message := "OpenAI sign-in did not complete. Request a new code and try again."
				if params.Error != nil && strings.TrimSpace(*params.Error) != "" {
					message = *params.Error
				}
				c.setAuthState(authSnapshot{Status: "error", RequiresOpenAIAuth: true, Message: message})
			}
		}
	case "error":
		var params struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &params) == nil && isAuthError(errors.New(params.Error.Message)) {
			go c.refreshAuth(true)
		}
	}
	var base struct {
		ThreadID string `json:"threadId"`
		TurnID   string `json:"turnId"`
	}
	_ = json.Unmarshal(raw, &base)
	if base.ThreadID == "" {
		return
	}
	switch method {
	case "turn/started":
		var params struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		}
		_ = json.Unmarshal(raw, &params)
		c.setActiveTurn(base.ThreadID, params.Turn.ID, nil)
	case "thread/status/changed":
		var params struct {
			Status threadRuntimeStatus `json:"status"`
		}
		_ = json.Unmarshal(raw, &params)
		c.applyThreadStatus(base.ThreadID, params.Status)
	case "turn/completed":
		c.clearActiveTurn(base.ThreadID, base.TurnID)
	default:
		if base.TurnID != "" {
			c.setActiveTurn(base.ThreadID, base.TurnID, nil)
		}
	}
	c.rememberTimelineItem(method, base.ThreadID, base.TurnID, raw)
	if method == "item/started" || method == "item/completed" || method == "item/commandExecution/outputDelta" || method == "turn/completed" {
		c.emit(base.ThreadID, streamEvent{"protocol", map[string]any{"type": "notification", "method": method, "params": json.RawMessage(raw)}})
	}
	switch method {
	case "item/agentMessage/delta":
		var p struct {
			Delta  string `json:"delta"`
			ItemID string `json:"itemId"`
		}
		_ = json.Unmarshal(raw, &p)
		c.emit(base.ThreadID, streamEvent{"delta", map[string]string{"text": p.Delta, "itemId": p.ItemID}})
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

// Command executions are streamed by app-server but are not currently included
// in its thread/read projection. Keep them materialized alongside lightweight
// user/agent item markers so history reloads can reconstruct the live order.
func (c *Codex) rememberTimelineItem(method, threadID, turnID string, raw json.RawMessage) {
	if turnID == "" {
		return
	}
	var timelineItem historyMessage
	switch method {
	case "item/started", "item/completed":
		var params struct {
			Item struct {
				Type             string  `json:"type"`
				ID               string  `json:"id"`
				Text             string  `json:"text"`
				Command          string  `json:"command"`
				CWD              string  `json:"cwd"`
				AggregatedOutput *string `json:"aggregatedOutput"`
				Status           string  `json:"status"`
				ExitCode         *int    `json:"exitCode"`
				DurationMs       *int64  `json:"durationMs"`
				Content          []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			} `json:"item"`
		}
		if json.Unmarshal(raw, &params) != nil || params.Item.ID == "" {
			return
		}
		switch params.Item.Type {
		case "userMessage":
			parts := make([]string, 0, len(params.Item.Content))
			for _, input := range params.Item.Content {
				if input.Type == "text" && strings.TrimSpace(input.Text) != "" {
					parts = append(parts, input.Text)
				}
			}
			timelineItem = historyMessage{Kind: "marker", ID: params.Item.ID, ItemType: params.Item.Type, Text: strings.TrimSpace(strings.Join(parts, "\n"))}
		case "agentMessage":
			timelineItem = historyMessage{Kind: "marker", ID: params.Item.ID, ItemType: params.Item.Type, Text: strings.TrimSpace(params.Item.Text)}
		case "commandExecution":
			timelineItem = historyMessage{
				Kind:       "command",
				ID:         params.Item.ID,
				ItemType:   params.Item.Type,
				Command:    params.Item.Command,
				CWD:        params.Item.CWD,
				Status:     params.Item.Status,
				ExitCode:   params.Item.ExitCode,
				DurationMs: params.Item.DurationMs,
			}
			if params.Item.AggregatedOutput != nil {
				timelineItem.Output = *params.Item.AggregatedOutput
			}
		default:
			return
		}
	case "item/commandExecution/outputDelta":
		var params struct {
			ItemID string `json:"itemId"`
			Delta  string `json:"delta"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ItemID == "" {
			return
		}
		timelineItem = historyMessage{Kind: "command", ID: params.ItemID, ItemType: "commandExecution", Output: params.Delta, Status: "inProgress"}
	case "item/agentMessage/delta":
		var params struct {
			ItemID string `json:"itemId"`
			Delta  string `json:"delta"`
		}
		if json.Unmarshal(raw, &params) != nil || params.ItemID == "" {
			return
		}
		timelineItem = historyMessage{Kind: "marker", ID: params.ItemID, ItemType: "agentMessage", Text: params.Delta}
	default:
		return
	}
	c.richMu.Lock()
	defer c.richMu.Unlock()
	if c.rich == nil {
		c.rich = make(map[string]map[string][]historyMessage)
	}
	if c.rich[threadID] == nil {
		c.rich[threadID] = make(map[string][]historyMessage)
	}
	items := c.rich[threadID][turnID]
	for index := range items {
		if items[index].ID != timelineItem.ID {
			continue
		}
		if timelineItem.Kind == "marker" {
			if method == "item/agentMessage/delta" {
				items[index].Text += timelineItem.Text
			} else if timelineItem.Text != "" {
				items[index].Text = timelineItem.Text
			}
			c.rich[threadID][turnID] = items
			return
		}
		items[index].Kind = timelineItem.Kind
		items[index].ItemType = timelineItem.ItemType
		if timelineItem.Command != "" {
			items[index].Command = timelineItem.Command
		}
		if timelineItem.CWD != "" {
			items[index].CWD = timelineItem.CWD
		}
		if method == "item/commandExecution/outputDelta" {
			items[index].Output += timelineItem.Output
		} else {
			items[index].Output = timelineItem.Output
		}
		if timelineItem.Status != "" {
			items[index].Status = timelineItem.Status
		}
		items[index].ExitCode = timelineItem.ExitCode
		items[index].DurationMs = timelineItem.DurationMs
		c.rich[threadID][turnID] = items
		return
	}
	// Bound each turn's bridge-only transcript cache. Persisted messages remain
	// owned by app-server; this only fills the command-event gap in thread/read.
	if len(items) >= 512 {
		items = append([]historyMessage(nil), items[len(items)-511:]...)
	}
	c.rich[threadID][turnID] = append(items, timelineItem)
}

func (c *Codex) richSnapshot(threadID string) map[string][]historyMessage {
	c.richMu.RLock()
	defer c.richMu.RUnlock()
	turns := c.rich[threadID]
	if len(turns) == 0 {
		return nil
	}
	snapshot := make(map[string][]historyMessage, len(turns))
	for turnID, items := range turns {
		snapshot[turnID] = append([]historyMessage(nil), items...)
	}
	return snapshot
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
	Type       string              `json:"type"`
	ThreadID   string              `json:"threadId"`
	ApprovalID string              `json:"approvalId"`
	Decision   string              `json:"decision"`
	Answers    map[string][]string `json:"answers"`
	Content    map[string]any      `json:"content"`
}
type chatRequest struct {
	Message   string `json:"message"`
	ThreadID  string `json:"threadId"`
	Workspace string `json:"workspace"`
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
	CWD       string `json:"cwd,omitempty"`
}

type workspaceSuggestion struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type historyMessage struct {
	ItemType   string `json:"-"`
	Kind       string `json:"kind,omitempty"`
	ID         string `json:"id,omitempty"`
	Role       string `json:"role,omitempty"`
	Text       string `json:"text,omitempty"`
	Command    string `json:"command,omitempty"`
	CWD        string `json:"cwd,omitempty"`
	Output     string `json:"output,omitempty"`
	Status     string `json:"status,omitempty"`
	ExitCode   *int   `json:"exitCode,omitempty"`
	DurationMs *int64 `json:"durationMs,omitempty"`
}

type threadTurn struct {
	ID     string            `json:"id"`
	Status string            `json:"status"`
	Items  []json.RawMessage `json:"items"`
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	state := "offline"
	if s.codex.ready.Load() {
		state = "ready"
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"codex": state, "workspace": s.workspace, "appServer": s.codex.endpoint, "auth": s.codex.authState()})
}

func (s *server) auth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		_ = json.NewEncoder(w).Encode(s.codex.authState())
	case http.MethodPost:
		if !s.codex.ready.Load() {
			http.Error(w, "codex app-server is unavailable", http.StatusServiceUnavailable)
			return
		}
		err := s.codex.startDeviceLogin(r.Context())
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
		}
		_ = json.NewEncoder(w).Encode(s.codex.authState())
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *server) completeWorkspaces(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	requested := r.URL.Query().Get("path")
	if len(requested) > 4096 {
		http.Error(w, "workspace path is too long", http.StatusBadRequest)
		return
	}
	suggestions, err := completeWorkspacePaths(requested, s.workspace)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{"suggestions": suggestions})
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
	auth, _ := json.Marshal(s.codex.authState())
	select {
	case events <- auth:
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
		switch command.Type {
		case "subscribe":
			if command.ThreadID == "" {
				continue
			}
			subscribeCtx, subscribeCancel := context.WithTimeout(ctx, 15*time.Second)
			_, err := s.ensureThread(subscribeCtx, command.ThreadID, "")
			subscribeCancel()
			if err != nil {
				s.codex.hub.broadcast(map[string]any{"type": "subscriptionError", "threadId": command.ThreadID, "message": err.Error()})
				continue
			}
			snapshot, _ := json.Marshal(s.codex.runtimeSnapshot(command.ThreadID))
			select {
			case events <- snapshot:
			default:
			}
		case "approval/decide":
			if err := s.codex.resolveApproval(command.ApprovalID, command.Decision, command.Answers, command.Content); err != nil {
				s.codex.hub.broadcast(map[string]any{"type": "approval/error", "approvalId": command.ApprovalID, "message": err.Error()})
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
	allWorkspaces := r.URL.Query().Get("scope") == "all"
	workspace := s.workspace
	if !allWorkspaces {
		var err error
		workspace, err = resolveWorkspace(r.URL.Query().Get("cwd"), s.workspace)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	var result struct {
		Data []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			Preview   string `json:"preview"`
			UpdatedAt int64  `json:"updatedAt"`
			Status    any    `json:"status"`
			CWD       string `json:"cwd"`
		} `json:"data"`
	}
	listParams := threadListParams(workspace, allWorkspaces)
	err := s.codex.call(ctx, "thread/list", listParams, &result)
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
		threads = append(threads, threadSummary{ID: item.ID, Title: title, Preview: item.Preview, UpdatedAt: item.UpdatedAt, Status: item.Status, CWD: item.CWD})
		seen[item.ID] = true
	}
	if allWorkspaces || workspace == s.workspace {
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
					CWD       string `json:"cwd"`
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
			threads = append([]threadSummary{{ID: pinned.Thread.ID, Title: title, Preview: pinned.Thread.Preview, UpdatedAt: pinned.Thread.UpdatedAt, Status: pinned.Thread.Status, CWD: pinned.Thread.CWD}}, threads...)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"threads": threads, "workspace": workspace})
}

func threadListParams(workspace string, allWorkspaces bool) map[string]any {
	params := map[string]any{
		"limit":         40,
		"sortKey":       "updated_at",
		"sortDirection": "desc",
	}
	if !allWorkspaces {
		params["cwd"] = workspace
	}
	return params
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
			ID     string              `json:"id"`
			Name   string              `json:"name"`
			CWD    string              `json:"cwd"`
			Status threadRuntimeStatus `json:"status"`
			Turns  []threadTurn        `json:"turns"`
		} `json:"thread"`
	}
	if err := s.codex.call(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, &result); err != nil {
		http.Error(w, "read thread: "+err.Error(), http.StatusBadGateway)
		return
	}

	messages := normalizeHistoryWithRich(result.Thread.Turns, s.codex.richSnapshot(threadID))
	runtime := s.codex.reconcileRuntime(threadID, result.Thread.Status, result.Thread.Turns)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"threadId": result.Thread.ID, "title": result.Thread.Name, "workspace": result.Thread.CWD, "messages": messages, "runtime": runtime})
}

func normalizeHistory(turns []threadTurn) []historyMessage {
	return normalizeHistoryWithRich(turns, nil)
}

func normalizeHistoryWithRich(turns []threadTurn, rich map[string][]historyMessage) []historyMessage {
	messages := make([]historyMessage, 0)
	for _, turn := range turns {
		persisted := make([]historyMessage, 0, len(turn.Items))
		for _, raw := range turn.Items {
			var item struct {
				Type             string `json:"type"`
				ID               string `json:"id"`
				Text             string `json:"text"`
				Command          string `json:"command"`
				CWD              string `json:"cwd"`
				AggregatedOutput string `json:"aggregatedOutput"`
				Status           string `json:"status"`
				ExitCode         *int   `json:"exitCode"`
				DurationMs       *int64 `json:"durationMs"`
				Content          []struct {
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
				text := strings.TrimSpace(strings.Join(parts, "\n"))
				if text != "" {
					persisted = append(persisted, historyMessage{ID: item.ID, ItemType: item.Type, Role: "user", Text: text})
				}
			case "agentMessage":
				if text := strings.TrimSpace(item.Text); text != "" {
					persisted = append(persisted, historyMessage{ID: item.ID, ItemType: item.Type, Role: "assistant", Text: text})
				}
			case "commandExecution":
				persisted = append(persisted, historyMessage{
					Kind:       "command",
					ID:         item.ID,
					ItemType:   item.Type,
					Command:    item.Command,
					CWD:        item.CWD,
					Output:     item.AggregatedOutput,
					Status:     item.Status,
					ExitCode:   item.ExitCode,
					DurationMs: item.DurationMs,
				})
			}
		}
		messages = append(messages, mergeTimelineOrder(persisted, rich[turn.ID])...)
		if turn.Status == "interrupted" {
			messages = append(messages, historyMessage{
				Kind:   "notice",
				ID:     turn.ID,
				Status: "interrupted",
				Text:   "Conversation interrupted — tell the model what to do differently. Something went wrong? Use /feedback to report the issue.",
			})
		}
	}
	return messages
}

// Merge the persisted item sequence with the live sequence using persisted
// user/agent IDs as anchors. This preserves old history order while placing
// bridge-only command items between the same messages seen by the CLI.
func mergeTimelineOrder(persisted, live []historyMessage) []historyMessage {
	ordered := make([]historyMessage, 0, len(persisted)+len(live))
	emitted := make(map[string]bool, len(persisted)+len(live))
	liveCursor := 0
	appendVisible := func(item historyMessage) {
		if item.Kind == "marker" || (item.ID != "" && emitted[item.ID]) {
			return
		}
		if item.ID != "" {
			emitted[item.ID] = true
		}
		ordered = append(ordered, item)
	}

	for _, persistedItem := range persisted {
		match := -1
		if persistedItem.ID != "" || persistedItem.Text != "" {
			for index := liveCursor; index < len(live); index++ {
				sameID := persistedItem.ID != "" && live[index].ID == persistedItem.ID
				sameContent := persistedItem.ItemType != "" &&
					live[index].ItemType == persistedItem.ItemType &&
					strings.TrimSpace(persistedItem.Text) != "" &&
					strings.TrimSpace(live[index].Text) == strings.TrimSpace(persistedItem.Text)
				if sameID || sameContent {
					match = index
					break
				}
			}
		}
		if match < 0 {
			appendVisible(persistedItem)
			continue
		}
		for liveCursor < match {
			appendVisible(live[liveCursor])
			liveCursor++
		}
		if live[match].Kind == "command" && persistedItem.Kind == "command" {
			appendVisible(live[match])
		} else {
			appendVisible(persistedItem)
		}
		liveCursor = match + 1
	}
	for liveCursor < len(live) {
		appendVisible(live[liveCursor])
		liveCursor++
	}
	return ordered
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
	workspace := ""
	if strings.TrimSpace(req.ThreadID) == "" {
		var err error
		workspace, err = resolveWorkspace(req.Workspace, s.workspace)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	threadID, err := s.ensureThread(ctx, req.ThreadID, workspace)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if s.codex.runtimeSnapshot(threadID).Working {
		http.Error(w, "this thread already has an active turn", http.StatusConflict)
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
	s.codex.setActiveTurn(threadID, started.Turn.ID, nil)

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	sse(w, "ready", map[string]string{"threadId": threadID, "turnId": started.Turn.ID, "workspace": workspace})
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
			// Browser navigation only detaches this SSE consumer. The shared turn
			// remains alive and can be observed or interrupted after reconnecting.
			return
		case <-time.After(25 * time.Second):
			_, _ = io.WriteString(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

func (s *server) ensureThread(ctx context.Context, requested, workspace string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested != "" {
		s.codex.knownMu.Lock()
		known := s.codex.known[requested]
		s.codex.knownMu.Unlock()
		if !known {
			var resumed map[string]any
			if err := s.codex.call(ctx, "thread/resume", map[string]any{"threadId": requested, "sandbox": "workspace-write", "approvalPolicy": "on-request"}, &resumed); err != nil {
				return "", fmt.Errorf("resume thread: %w", err)
			}
			s.codex.knownMu.Lock()
			s.codex.known[requested] = true
			s.codex.knownMu.Unlock()
		}
		return requested, nil
	}
	if workspace == "" {
		workspace = s.workspace
	}
	params := map[string]any{"cwd": workspace, "runtimeWorkspaceRoots": []string{workspace}, "sandbox": "workspace-write", "approvalPolicy": "on-request", "ephemeral": false}
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

func resolveWorkspace(requested, fallback string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		requested = fallback
	}
	if !filepath.IsAbs(requested) {
		return "", errors.New("workspace path must be absolute")
	}
	resolved, err := filepath.Abs(filepath.Clean(requested))
	if err != nil {
		return "", fmt.Errorf("resolve workspace path: %w", err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("workspace path is unavailable: %w", err)
	}
	if !info.IsDir() {
		return "", errors.New("workspace path must be a directory")
	}
	return resolved, nil
}

func completeWorkspacePaths(requested, fallback string) ([]workspaceSuggestion, error) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		requested = filepath.Dir(fallback) + string(os.PathSeparator)
	}
	if !filepath.IsAbs(requested) {
		return nil, errors.New("workspace path must be absolute")
	}

	cleaned := filepath.Clean(requested)
	searchDir := cleaned
	prefix := ""
	if info, err := os.Stat(cleaned); err != nil || !info.IsDir() {
		searchDir = filepath.Dir(cleaned)
		prefix = filepath.Base(cleaned)
	}
	entries, err := os.ReadDir(searchDir)
	if err != nil {
		return nil, fmt.Errorf("list workspace paths: %w", err)
	}

	prefix = strings.ToLower(prefix)
	suggestions := make([]workspaceSuggestion, 0, 40)
	for _, entry := range entries {
		if !strings.HasPrefix(strings.ToLower(entry.Name()), prefix) {
			continue
		}
		path := filepath.Join(searchDir, entry.Name())
		isDir := entry.IsDir()
		if !isDir && entry.Type()&os.ModeSymlink != 0 {
			if info, statErr := os.Stat(path); statErr == nil {
				isDir = info.IsDir()
			}
		}
		if !isDir {
			continue
		}
		suggestions = append(suggestions, workspaceSuggestion{Name: entry.Name(), Path: path})
		if len(suggestions) == 40 {
			break
		}
	}
	sort.Slice(suggestions, func(i, j int) bool {
		return strings.ToLower(suggestions[i].Path) < strings.ToLower(suggestions[j].Path)
	})
	return suggestions, nil
}

func (s *server) interrupt(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req interruptRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ThreadID == "" {
		http.Error(w, "threadId is required", http.StatusBadRequest)
		return
	}
	if req.TurnID == "" {
		req.TurnID = s.codex.runtimeSnapshot(req.ThreadID).TurnID
	}
	if req.TurnID == "" {
		http.Error(w, "the active turn id is unavailable", http.StatusConflict)
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
	appRoot, err := os.Getwd()
	if err != nil {
		log.Fatal(err)
	}
	if filepath.Base(appRoot) == "server" {
		appRoot = filepath.Dir(appRoot)
	}
	appRoot, err = filepath.Abs(appRoot)
	if err != nil {
		log.Fatal(err)
	}

	workspace := env("CODEX_WORKSPACE", "")
	if workspace == "" {
		workspace = appRoot
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
		_, resumeErr := s.ensureThread(ctx, threadID, "")
		cancel()
		if resumeErr != nil {
			log.Printf("bootstrap thread %s could not be resumed: %v", threadID, resumeErr)
			continue
		}
		log.Printf("resumed bootstrap thread: %s", threadID)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", s.health)
	mux.HandleFunc("/api/auth", s.auth)
	mux.HandleFunc("/api/workspaces/complete", s.completeWorkspaces)
	mux.HandleFunc("/api/ws", s.websocket)
	mux.HandleFunc("/api/threads", s.threads)
	mux.HandleFunc("/api/threads/", s.threads)
	mux.HandleFunc("/api/chat", s.chat)
	mux.HandleFunc("/api/interrupt", s.interrupt)
	distPath, err := filepath.Abs(env("WEB_DIST", filepath.Join(appRoot, "dist")))
	if err != nil {
		log.Fatalf("invalid WEB_DIST: %v", err)
	}
	dist := http.Dir(distPath)
	mux.Handle("/", spaHandler(dist))

	address := "0.0.0.0:" + env("PORT", "40001")
	log.Printf("Codex web bridge listening at http://%s", address)
	log.Printf("shared Codex app-server listening at %s", appServerURL)
	log.Printf("remote TUI: codex resume --remote %s <SESSION_ID>", appServerURL)
	log.Printf("workspace: %s", absWorkspace)
	log.Printf("web assets: %s", distPath)
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
