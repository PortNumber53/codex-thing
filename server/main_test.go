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
