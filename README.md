# Codex Local Web

A Vite + React chat interface backed by a small Go service and one shared Codex app-server. Browser sessions and official Codex terminal UIs can subscribe to the same live threads.

## Run it

Requirements: Node 20+, Go 1.23+, and an authenticated `codex` CLI on `PATH`.

For a persistent Linux or macOS installation, including the `SERVER` deployment
from `WORKSTATION`, follow [INSTALL.md](INSTALL.md). The production installer builds
the Vite UI and runs one managed Go service; Vite's port `40000` is development
only.

```bash
npm install
```

During development, run these in two terminals:

```bash
npm run dev:server
npm run dev
```

Open `http://<machine-ip>:40000`. The development UI listens on all interfaces and proxies API calls to the Go service on port `40001`.

The Go service starts Codex app-server on loopback port `40002`. Join that same live runtime from a terminal with:

```bash
codex resume --remote ws://127.0.0.1:40002 <SESSION_ID>
```

You can run more than one remote TUI. Do not also resume the thread with a standalone `codex resume` command lacking `--remote`; that creates a separate runtime and will not receive live events.

For a single production-style server:

```bash
npm run build
npm run server
```

Then open <http://127.0.0.1:40001>.

## Configuration

- `PORT` — Go server port (default `40001`)
- `CODEX_BIN` — Codex executable (default `codex`)
- `CODEX_APP_SERVER_URL` — shared app-server WebSocket endpoint (default `ws://127.0.0.1:40002`)
- `CODEX_WORKSPACE` — workspace exposed to Codex (default: repository root/current directory)
- `WEB_DIST` — directory containing the built Vite UI (default: `dist` under the application working directory)
- `CODEX_MODEL` — optional model override; omitted to use the local Codex default
- `CODEX_BOOTSTRAP_THREADS` — comma-separated thread IDs that Go resumes when its app-server starts and always includes in Recent Sessions (default: empty)

The Vite and Go development listeners bind to all interfaces. Only run them on a trusted network or protect them with a firewall/VPN: any client that can reach the UI can prompt Codex against the configured workspace. The Codex app-server listener remains on `127.0.0.1` by default and must not be exposed directly to the network.

Threads use `workspace-write` sandboxing and `approvalPolicy: on-request`. Supported command, file-change, permission, and user-input requests are synchronized between the browser and remote terminal UIs attached to the same app-server.

Codex app-server's TCP WebSocket transport and remote TUI mode are currently experimental. The Go gateway is the only component intended to be reachable from other machines.
