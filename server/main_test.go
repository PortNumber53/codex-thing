package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
	result, err := approvalResponse(modern, "always")
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
	result, err = approvalResponse(legacy, "accept")
	if err != nil || result["decision"] != "approved" {
		t.Fatalf("unexpected legacy approval response: %#v (%v)", result, err)
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
