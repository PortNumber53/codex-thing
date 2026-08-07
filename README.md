# Codex Local Web

Codex Local Web is a browser interface for a shared Codex runtime. It connects a
React chat UI and official Codex terminal clients to the same Codex app-server so
people can follow and control one conversation from multiple browsers and
terminals in real time.

This project is useful when Codex runs on a workstation or development server
but needs to remain accessible from another trusted machine. The browser talks
only to the Go bridge; the underlying Codex app-server stays on loopback.

## What it provides

- Create, discover, and resume Codex threads across workspaces.
- Stream assistant output, reasoning summaries, commands, tool activity, file
  changes, interruptions, and turn status to every connected browser.
- Keep multiple browser tabs and remote Codex terminal UIs synchronized through
  one app-server process.
- Answer command approvals, file-change approvals, permission requests, MCP
  elicitations, and model questions from the browser or terminal.
- Retain active-turn and pending-approval state after a browser refresh, including
  the ability to interrupt a running turn.
- Select a workspace for a new conversation with server-backed path completion.
- Serve the production React application directly from the Go binary's HTTP
  server.

## Architecture

```text
 Browser A ─┐
 Browser B ─┼── HTTP + WebSocket ──> Go bridge ── WebSocket RPC ──> Codex app-server
 Browser C ─┘                              │                              ▲
                                          │                              │
                                          └── serves built React UI      │
                                                                         │
 Codex TUI ─────────────────────────── codex --remote ────────────────────┘
```

The Go bridge starts a Codex app-server when none is available, or reconnects to
an already-running compatible process. It translates browser actions into the
app-server protocol and broadcasts Codex notifications and runtime snapshots to
subscribed browsers.

Thread history remains owned by Codex. The bridge supplements that history with
live command and tool events that are not always present in the app-server's
thread projection, preserving the order users see while a turn is running.

## Synchronization model

All clients must connect to the same app-server process to share live state.
Browser clients do this through the Go bridge. Terminal clients do it through
Codex's `--remote` option or the shell wrapper installed by this project.

Resuming the same stored thread with a standalone Codex process does not attach
that process to the shared runtime. It creates a separate live session and will
not receive browser messages, approvals, or turn updates.

When a browser reconnects, the bridge reads the stored thread and combines it
with the current runtime snapshot. This restores working state, the active turn,
and unresolved approval prompts without relying on interval polling.

## Components

| Component | Responsibility |
| --- | --- |
| `src/` | React chat interface, transcript rendering, workspace selection, and approval controls |
| `server/` | Go HTTP/WebSocket bridge and Codex app-server protocol client |
| `scripts/install.sh` | Generic Linux systemd-user and macOS LaunchAgent installation |
| `scripts/install-shell-wrapper.sh` | Idempotent zsh, bash, and fish integration for shared terminal sessions |
| `INSTALL.md` | Complete installation, configuration, security, update, and troubleshooting runbook |

In development, Vite serves the UI on port `40000` and proxies API traffic to
the Go bridge on port `40001`. In production, Vite builds static assets and only
the Go service runs. The shared Codex app-server listens on loopback port `40002`
by default.

## Development

After completing the prerequisites and dependency setup in
[INSTALL.md](INSTALL.md), start the backend and frontend in separate terminals:

```bash
npm run dev:server
npm run dev
```

The relevant package commands are:

| Command | Purpose |
| --- | --- |
| `npm run dev` | Start the Vite development UI |
| `npm run dev:server` | Run the Go bridge from source |
| `npm run build` | Build the production React assets |
| `npm run server` | Run the Go bridge from source with the built UI |

Development hostname configuration, production services, shell integration, and
all environment variables are documented only in [INSTALL.md](INSTALL.md).

## Security

Codex Local Web does not currently provide application-level authentication. The
Go listener is intended for a trusted LAN or private VPN, and anyone who can
reach it can interact with Codex using the service user's permissions and
configured workspace.

The app-server endpoint should remain on loopback and should never be exposed
directly. Use an SSH tunnel when a terminal client on another machine needs to
join the shared runtime. See [INSTALL.md](INSTALL.md) for the complete deployment
and network-security checklist.

## Project status

Codex app-server's TCP WebSocket transport and remote terminal mode are
experimental. Protocol changes in new Codex CLI releases may require bridge
updates. The Go gateway is the only component designed to be reachable from
other machines.

## Installation

See [INSTALL.md](INSTALL.md). It is intentionally self-contained so a human or AI
installation agent can deploy the project without inspecting the source code.
