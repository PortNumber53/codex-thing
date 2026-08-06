package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestWebsocketBroadcastsCodexNotifications(t *testing.T) {
	codex := &Codex{hub: newSocketHub()}
	s := &server{codex: codex}
	httpServer := httptest.NewServer(http.HandlerFunc(s.websocket))
	defer httpServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http")+"/api/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	_, connected, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var initial map[string]any
	if err := json.Unmarshal(connected, &initial); err != nil || initial["type"] != "connected" {
		t.Fatalf("unexpected initial event: %s (%v)", connected, err)
	}

	codex.hub.broadcast(map[string]any{
		"type":   "notification",
		"method": "item/agentMessage/delta",
		"params": map[string]string{"threadId": "thread-1", "delta": "hello"},
	})
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var event struct {
		Type   string `json:"type"`
		Method string `json:"method"`
		Params struct {
			ThreadID string `json:"threadId"`
			Delta    string `json:"delta"`
		} `json:"params"`
	}
	if err := json.Unmarshal(payload, &event); err != nil {
		t.Fatal(err)
	}
	if event.Type != "notification" || event.Method != "item/agentMessage/delta" || event.Params.ThreadID != "thread-1" || event.Params.Delta != "hello" {
		t.Fatalf("unexpected broadcast: %+v", event)
	}
}

func TestNormalizeHistoryIncludesCommandsAndInterruptions(t *testing.T) {
	exitCode := 0
	duration := int64(245)
	command, err := json.Marshal(map[string]any{
		"type":             "commandExecution",
		"id":               "item-command",
		"command":          "git status --short",
		"cwd":              "/workspace",
		"aggregatedOutput": " M server/main.go\n",
		"status":           "completed",
		"exitCode":         exitCode,
		"durationMs":       duration,
	})
	if err != nil {
		t.Fatal(err)
	}

	items := normalizeHistory([]threadTurn{{ID: "turn-1", Status: "interrupted", Items: []json.RawMessage{command}}})
	if len(items) != 2 {
		t.Fatalf("expected command and notice, got %#v", items)
	}
	if items[0].Kind != "command" || items[0].Command != "git status --short" || items[0].Output != " M server/main.go\n" || items[0].ExitCode == nil || *items[0].ExitCode != 0 {
		t.Fatalf("unexpected command item: %#v", items[0])
	}
	if items[1].Kind != "notice" || items[1].Status != "interrupted" || !strings.Contains(items[1].Text, "Conversation interrupted") {
		t.Fatalf("unexpected interruption notice: %#v", items[1])
	}
}

func TestLiveCommandsAreMaterializedIntoHistory(t *testing.T) {
	codex := &Codex{}
	started := json.RawMessage(`{
		"threadId":"thread-1",
		"turnId":"turn-1",
		"item":{"type":"commandExecution","id":"command-1","command":"git status --short","cwd":"/workspace","status":"inProgress"}
	}`)
	delta := json.RawMessage(`{"threadId":"thread-1","turnId":"turn-1","itemId":"command-1","delta":" M server/main.go\n"}`)
	completed := json.RawMessage(`{
		"threadId":"thread-1",
		"turnId":"turn-1",
		"item":{"type":"commandExecution","id":"command-1","command":"git status --short","cwd":"/workspace","aggregatedOutput":" M server/main.go\n","status":"completed","exitCode":0,"durationMs":42}
	}`)

	codex.rememberTimelineItem("item/started", "thread-1", "turn-1", started)
	codex.rememberTimelineItem("item/commandExecution/outputDelta", "thread-1", "turn-1", delta)
	codex.rememberTimelineItem("item/completed", "thread-1", "turn-1", completed)
	items := normalizeHistoryWithRich(
		[]threadTurn{{ID: "turn-1", Status: "completed"}},
		codex.richSnapshot("thread-1"),
	)

	if len(items) != 1 {
		t.Fatalf("expected one materialized command, got %#v", items)
	}
	if items[0].Kind != "command" || items[0].Command != "git status --short" || items[0].Output != " M server/main.go\n" || items[0].Status != "completed" {
		t.Fatalf("unexpected materialized command: %#v", items[0])
	}
	if items[0].ExitCode == nil || *items[0].ExitCode != 0 || items[0].DurationMs == nil || *items[0].DurationMs != 42 {
		t.Fatalf("missing completion metadata: %#v", items[0])
	}
}

func TestLiveTimelinePlacesCommandsBetweenPersistedMessages(t *testing.T) {
	user := json.RawMessage(`{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"Please inspect it"}]}`)
	before := json.RawMessage(`{"type":"agentMessage","id":"agent-before","text":"I will inspect the repository."}`)
	after := json.RawMessage(`{"type":"agentMessage","id":"agent-after","text":"The repository is clean."}`)
	codex := &Codex{}
	codex.rememberTimelineItem("item/started", "thread-1", "turn-1", json.RawMessage(`{"item":{"type":"userMessage","id":"user-1"}}`))
	codex.rememberTimelineItem("item/agentMessage/delta", "thread-1", "turn-1", json.RawMessage(`{"itemId":"live-agent-before","delta":"I will inspect the repository."}`))
	codex.rememberTimelineItem("item/started", "thread-1", "turn-1", json.RawMessage(`{"item":{"type":"commandExecution","id":"command-1","command":"git status --short","status":"inProgress"}}`))
	codex.rememberTimelineItem("item/agentMessage/delta", "thread-1", "turn-1", json.RawMessage(`{"itemId":"live-agent-after","delta":"The repository is clean."}`))

	items := normalizeHistoryWithRich(
		[]threadTurn{{ID: "turn-1", Status: "completed", Items: []json.RawMessage{user, before, after}}},
		codex.richSnapshot("thread-1"),
	)
	if len(items) != 4 {
		t.Fatalf("expected four ordered transcript items, got %#v", items)
	}
	if items[0].ID != "user-1" || items[1].ID != "agent-before" || items[2].ID != "command-1" || items[3].ID != "agent-after" {
		t.Fatalf("unexpected transcript order: %#v", items)
	}
}

func TestApprovalResponsesMatchProtocolVersion(t *testing.T) {
	modern := pendingApproval{
		Method:  "item/commandExecution/requestApproval",
		Request: commandApproval{ProposedExecPrefix: []string{"npm", "run", "dev:server"}},
	}
	result, err := approvalResponse(modern, "always", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	decision, ok := result["decision"].(map[string]any)
	if !ok {
		t.Fatalf("expected structured execpolicy decision, got %#v", result)
	}
	amendment, ok := decision["acceptWithExecpolicyAmendment"].(map[string]any)
	if !ok {
		t.Fatalf("missing execpolicy amendment: %#v", result)
	}
	prefix, ok := amendment["execpolicy_amendment"].([]string)
	if !ok || strings.Join(prefix, " ") != "npm run dev:server" {
		t.Fatalf("unexpected execpolicy prefix: %#v", result)
	}

	legacy := pendingApproval{Method: "execCommandApproval"}
	result, err = approvalResponse(legacy, "accept", nil, nil)
	if err != nil || result["decision"] != "approved" {
		t.Fatalf("unexpected legacy approval response: %#v (%v)", result, err)
	}
}

func TestBrowserApprovalWaitsForAppServerResolution(t *testing.T) {
	received := make(chan []byte, 1)
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		_, payload, err := conn.Read(r.Context())
		if err == nil {
			received <- payload
		}
	}))
	defer httpServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	codex := &Codex{
		conn:   conn,
		hub:    newSocketHub(),
		active: map[string]activeTurn{"thread-1": {TurnID: "turn-1", ActiveFlags: []string{"waitingOnApproval"}}},
		approvals: map[string]pendingApproval{
			"approval-1": {
				Request: commandApproval{ID: "approval-1", ThreadID: "thread-1", TurnID: "turn-1", Command: "npm run build"},
				Method:  "item/commandExecution/requestApproval",
				RPCID:   json.RawMessage(`31`),
			},
		},
	}
	if err := codex.resolveApproval("approval-1", "accept", nil, nil); err != nil {
		t.Fatal(err)
	}

	select {
	case payload := <-received:
		var response struct {
			ID     int `json:"id"`
			Result struct {
				Decision string `json:"decision"`
			} `json:"result"`
		}
		if err := json.Unmarshal(payload, &response); err != nil {
			t.Fatal(err)
		}
		if response.ID != 31 || response.Result.Decision != "accept" {
			t.Fatalf("unexpected app-server response: %s", payload)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for app-server response")
	}

	snapshot := codex.runtimeSnapshot("thread-1")
	if len(snapshot.Approvals) != 1 || !snapshot.Approvals[0].Submitted {
		t.Fatalf("submitted approval should remain pending until app-server resolves it: %#v", snapshot.Approvals)
	}
	if len(snapshot.ActiveFlags) != 1 || snapshot.ActiveFlags[0] != "waitingOnApproval" {
		t.Fatalf("approval wait state cleared before app-server resolution: %#v", snapshot.ActiveFlags)
	}

	codex.handleNotification("serverRequest/resolved", json.RawMessage(`{"threadId":"thread-1","requestId":31}`))
	if got := codex.runtimeSnapshot("thread-1"); len(got.Approvals) != 0 || len(got.ActiveFlags) != 0 {
		t.Fatalf("app-server resolution did not clear approval: %#v", got)
	}
}

func TestInteractiveApprovalResponsesMatchProtocol(t *testing.T) {
	fileChange, err := approvalResponse(
		pendingApproval{Method: "item/fileChange/requestApproval"},
		"always",
		nil,
		nil,
	)
	if err != nil || fileChange["decision"] != "acceptForSession" {
		t.Fatalf("unexpected file-change response: %#v (%v)", fileChange, err)
	}

	requestedPermissions := map[string]any{
		"network":    map[string]any{"enabled": true},
		"fileSystem": map[string]any{"write": []any{"/workspace"}},
	}
	permissions, err := approvalResponse(
		pendingApproval{
			Method:  "item/permissions/requestApproval",
			Request: commandApproval{Permissions: requestedPermissions},
		},
		"always",
		nil,
		nil,
	)
	if err != nil || permissions["scope"] != "session" {
		t.Fatalf("unexpected permission response: %#v (%v)", permissions, err)
	}
	if permissions["permissions"] == nil {
		t.Fatalf("granted permissions were omitted: %#v", permissions)
	}
	denied, err := approvalResponse(
		pendingApproval{
			Method:  "item/permissions/requestApproval",
			Request: commandApproval{Permissions: requestedPermissions},
		},
		"decline",
		nil,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := denied["permissions"].(map[string]any); !ok || len(got) != 0 {
		t.Fatalf("denied permissions should be empty: %#v", denied)
	}

	answers, err := approvalResponse(
		pendingApproval{Method: "item/tool/requestUserInput"},
		"submit",
		map[string][]string{"strategy": {"Keep the patch small"}},
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(answers)
	if string(encoded) != `{"answers":{"strategy":{"answers":["Keep the patch small"]}}}` {
		t.Fatalf("unexpected user-input response: %s", encoded)
	}
}

func TestHandleServerRequestCapturesEveryInteractivePromptKind(t *testing.T) {
	tests := []struct {
		method string
		raw    string
		kind   string
	}{
		{
			method: "item/commandExecution/requestApproval",
			raw:    `{"threadId":"thread-1","turnId":"turn-1","itemId":"command-1","command":"npm run build","proposedExecpolicyAmendment":{"command":["npm","run","build"]}}`,
			kind:   "command",
		},
		{
			method: "item/fileChange/requestApproval",
			raw:    `{"threadId":"thread-1","turnId":"turn-1","itemId":"patch-1","reason":"Update generated files"}`,
			kind:   "fileChange",
		},
		{
			method: "item/permissions/requestApproval",
			raw:    `{"threadId":"thread-1","turnId":"turn-1","itemId":"permissions-1","cwd":"/workspace","permissions":{"network":{"enabled":true}}}`,
			kind:   "permissions",
		},
		{
			method: "item/tool/requestUserInput",
			raw:    `{"threadId":"thread-1","turnId":"turn-1","itemId":"question-1","questions":[{"id":"strategy","header":"Approach","question":"Which approach?","options":[{"label":"Small patch","description":"Keep scope narrow"}]}]}`,
			kind:   "userInput",
		},
		{
			method: "mcpServer/elicitation/request",
			raw:    `{"threadId":"thread-1","turnId":"turn-1","serverName":"example","mode":"form","message":"Share configuration?","requestedSchema":{"type":"object","properties":{}}}`,
			kind:   "mcpElicitation",
		},
	}

	for index, test := range tests {
		codex := &Codex{
			hub:       newSocketHub(),
			active:    make(map[string]activeTurn),
			approvals: make(map[string]pendingApproval),
		}
		if !codex.handleServerRequest(json.RawMessage(strconv.Itoa(index+1)), test.method, json.RawMessage(test.raw)) {
			t.Fatalf("%s was not handled", test.method)
		}
		snapshot := codex.runtimeSnapshot("thread-1")
		if len(snapshot.Approvals) != 1 || snapshot.Approvals[0].Kind != test.kind {
			t.Fatalf("unexpected %s snapshot: %#v", test.method, snapshot.Approvals)
		}
		if test.kind == "command" && strings.Join(snapshot.Approvals[0].ProposedExecPrefix, " ") != "npm run build" {
			t.Fatalf("structured execpolicy amendment was not captured: %#v", snapshot.Approvals[0])
		}
	}
}

func TestRuntimeSnapshotSurvivesBrowserReconnect(t *testing.T) {
	codex := &Codex{
		active: map[string]activeTurn{"thread-1": {TurnID: "turn-1", ActiveFlags: []string{"waitingOnApproval"}}},
		approvals: map[string]pendingApproval{
			"approval-1": {Request: commandApproval{ID: "approval-1", ThreadID: "thread-1", TurnID: "turn-1", Command: "npm run dev:server", StartedAtMs: 1}},
		},
	}
	snapshot := codex.runtimeSnapshot("thread-1")
	if !snapshot.Working || snapshot.TurnID != "turn-1" {
		t.Fatalf("active turn was not restored: %#v", snapshot)
	}
	if len(snapshot.Approvals) != 1 || snapshot.Approvals[0].Command != "npm run dev:server" {
		t.Fatalf("pending approval was not restored: %#v", snapshot)
	}
}

func TestServerRequestResolvedClearsApprovalAnsweredByAnotherClient(t *testing.T) {
	codex := &Codex{
		hub:    newSocketHub(),
		active: map[string]activeTurn{"thread-1": {TurnID: "turn-1", ActiveFlags: []string{"waitingOnApproval"}}},
		approvals: map[string]pendingApproval{
			"approval-1": {
				Request: commandApproval{ID: "approval-1", ThreadID: "thread-1", TurnID: "turn-1", Command: "npm run dev:server"},
				RPCID:   json.RawMessage(`"request-7"`),
			},
		},
	}
	events := codex.hub.subscribe()
	defer codex.hub.unsubscribe(events)

	codex.handleNotification("serverRequest/resolved", json.RawMessage(`{"threadId":"thread-1","requestId":"request-7"}`))
	snapshot := codex.runtimeSnapshot("thread-1")
	if len(snapshot.Approvals) != 0 {
		t.Fatalf("approval resolved by another client was not dismissed: %#v", snapshot.Approvals)
	}
	if strings.Join(snapshot.ActiveFlags, ",") != "" {
		t.Fatalf("waiting-on-approval flag was not cleared: %#v", snapshot.ActiveFlags)
	}
	resolvedBroadcast := false
	for range 3 {
		var event struct {
			Type       string `json:"type"`
			ApprovalID string `json:"approvalId"`
		}
		if err := json.Unmarshal(<-events, &event); err != nil {
			t.Fatal(err)
		}
		if event.Type == "approval/resolved" && event.ApprovalID == "approval-1" {
			resolvedBroadcast = true
		}
	}
	if !resolvedBroadcast {
		t.Fatal("connected browsers were not notified that the approval resolved")
	}
}

func TestServerRequestResolvedKeepsWaitingForAnotherApproval(t *testing.T) {
	codex := &Codex{
		hub:    newSocketHub(),
		active: map[string]activeTurn{"thread-1": {TurnID: "turn-1", ActiveFlags: []string{"waitingOnApproval"}}},
		approvals: map[string]pendingApproval{
			"approval-1": {Request: commandApproval{ID: "approval-1", ThreadID: "thread-1"}, RPCID: json.RawMessage(`1`)},
			"approval-2": {Request: commandApproval{ID: "approval-2", ThreadID: "thread-1"}, RPCID: json.RawMessage(`2`)},
		},
	}

	codex.handleNotification("serverRequest/resolved", json.RawMessage(`{"threadId":"thread-1","requestId":1}`))
	snapshot := codex.runtimeSnapshot("thread-1")
	if len(snapshot.Approvals) != 1 || snapshot.Approvals[0].ID != "approval-2" {
		t.Fatalf("unexpected remaining approvals: %#v", snapshot.Approvals)
	}
	if len(snapshot.ActiveFlags) != 1 || snapshot.ActiveFlags[0] != "waitingOnApproval" {
		t.Fatalf("waiting-on-approval flag cleared too early: %#v", snapshot.ActiveFlags)
	}
}

func TestResolveWorkspaceRequiresAbsoluteDirectory(t *testing.T) {
	workspace := t.TempDir()
	resolved, err := resolveWorkspace(workspace, "")
	if err != nil || resolved != workspace {
		t.Fatalf("expected valid workspace, got %q (%v)", resolved, err)
	}
	if _, err := resolveWorkspace("relative/path", workspace); err == nil {
		t.Fatal("expected relative workspace to be rejected")
	}
	file := filepath.Join(workspace, "not-a-directory")
	if err := os.WriteFile(file, []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := resolveWorkspace(file, workspace); err == nil {
		t.Fatal("expected file workspace to be rejected")
	}
}

func TestCompleteWorkspacePathsReturnsMatchingDirectoriesOnly(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"alpha", "alpine", "beta"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "also-a-file"), []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}

	suggestions, err := completeWorkspacePaths(filepath.Join(root, "al"), root)
	if err != nil {
		t.Fatal(err)
	}
	if len(suggestions) != 2 || suggestions[0].Name != "alpha" || suggestions[1].Name != "alpine" {
		t.Fatalf("unexpected workspace suggestions: %#v", suggestions)
	}
	for _, suggestion := range suggestions {
		if suggestion.Name == "also-a-file" {
			t.Fatalf("file leaked into directory suggestions: %#v", suggestions)
		}
	}
	if _, err := completeWorkspacePaths("relative", root); err == nil {
		t.Fatal("expected relative completion path to be rejected")
	}
}
