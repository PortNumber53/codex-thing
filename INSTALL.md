# Installing Codex Local Web

This document is the complete installation runbook. An installation agent should
be able to follow it without reading the application source.

## What gets installed

The production installation has three runtime pieces:

1. `codex-thing-server`, a Go HTTP/WebSocket bridge listening on all interfaces
   on port `40001` by default.
2. A Codex `app-server` child process listening only on
   `ws://127.0.0.1:40002`.
3. A shell function named `codex` that adds `--remote
   ws://127.0.0.1:40002` to interactive Codex commands. Administrative commands
   such as `codex login`, `codex app-server`, and `codex exec` continue to use the
   normal local CLI path.

Vite is a build dependency, not a second production daemon. The installer runs
`vite build`, and the Go process serves the resulting static UI on port `40001`.
Port `40000` is only used by `npm run dev` during development.

Every browser connected to the same Go bridge receives live thread, turn, and
approval updates over WebSocket. Terminal UIs must connect to that same
app-server with `--remote` to participate in the same live runtime.

## Security boundary

The web listener intentionally binds to `0.0.0.0`, and the application does not
provide its own authentication. Anyone who can reach port `40001` can interact
with Codex using the service user's permissions and configured workspace.

- Only expose port `40001` on a trusted LAN or private VPN such as Tailscale.
- Restrict it with the host firewall when the network contains untrusted clients.
- Never expose port `40002`. It must remain bound to loopback.
- Do not put this service directly on the public internet without an
  authenticated reverse proxy.
- Use a dedicated, non-root service account when installing on a shared host.

## Requirements

Install these commands before continuing:

| Command | Minimum version | Used for |
| --- | ---: | --- |
| `node` and `npm` | Node 20 | Building the React/Vite UI |
| `go` | Go 1.23 | Building the Go bridge |
| `codex` | Codex CLI 0.146.1 | Running the shared app-server |
| `git` | Any current version | Generic installation and updates |
| `systemctl` | Linux with systemd | Linux user service |
| `launchctl` | Current macOS | macOS LaunchAgent |

Example prerequisite installation commands follow. Use the platform's supported
package source if these commands are not appropriate for that host.

Arch Linux, including `SERVER`:

```bash
sudo pacman -S --needed nodejs npm go git rsync
sudo npm install -g @openai/codex@latest
```

macOS with Homebrew:

```bash
brew install node go git
npm install -g @openai/codex@latest
```

On Debian or Ubuntu, install current Node and Go releases from their official
repositories rather than accepting distribution versions below the minimums,
then install Codex:

```bash
sudo apt-get update
sudo apt-get install -y git rsync
sudo npm install -g @openai/codex@latest
```

Verify the actual versions after package installation; the application installer
also refuses unsupported versions:

```bash
node --version
npm --version
go version
codex --version
```

The service runs as the user who executes the installer. Authenticate Codex as
that same user:

```bash
codex login status || codex login --device-auth
codex login status
```

The second command must succeed before installation. On a headless server,
device authentication is preferred. If device authentication is unavailable,
copy only `~/.codex/auth.json` from an already authenticated trusted machine:

```bash
ssh SERVER 'mkdir -p ~/.codex && chmod 700 ~/.codex'
scp ~/.codex/auth.json SERVER:~/.codex/auth.json
ssh SERVER 'chmod 600 ~/.codex/auth.json && codex login status'
```

Treat `auth.json` like a password. Do not commit it, log it, or copy the entire
`.codex` directory.

`codex login status` verifies that stored credentials exist, but some CLI
versions can still report success after a refresh token expires. After starting
the service, inspect its logs. If they contain `token_expired` or
`refresh_token_expired`, run `codex logout` followed by `codex login
--device-auth` as the service user, or replace `auth.json` using the secure copy
procedure above, then restart the service.

## Generic one-host installation

The commands below install into a specific per-user folder and use the user's
home directory as the initial workspace. Replace `SERVER` with the SSH hostname.
Run the commands directly on the host if SSH is not needed.

```bash
ssh SERVER
export CODEX_THING_DIR="$HOME/.local/share/codex-thing"
git clone https://github.com/PortNumber53/codex-thing.git "$CODEX_THING_DIR"
cd "$CODEX_THING_DIR"
codex login status || codex login --device-auth
./scripts/install.sh \
  --install-dir "$CODEX_THING_DIR" \
  --workspace "$HOME" \
  --service auto \
  --shells auto
```

`--service auto` installs a systemd user service on Linux or a LaunchAgent on
macOS. The installer performs exact dependency installation with `npm ci`, builds
the Vite UI and Go binary, writes `config.env`, enables and starts the service,
and installs idempotent managed shell wrapper blocks.

Restart every open shell after the installer finishes:

```bash
exec "$SHELL" -l
```

Existing shells retain their old function definitions until restarted. Tell the
human operator about this step even when an AI agent performed the installation.

Verify the service from the host:

```bash
curl --fail http://127.0.0.1:40001/api/health
```

Then open `http://SERVER:40001` from another machine. If the hostname is not
resolvable there, use the server's trusted LAN or VPN IP address.

### Linux service details

The installer creates:

- `~/.config/systemd/user/codex-thing.service`
- `INSTALL_DIR/config.env`
- `INSTALL_DIR/bin/codex-thing-server`

It enables the unit with `systemctl --user enable --now`. A user service can use
the user's Codex credentials without putting credentials in a root service. To
start it during boot before the user logs in, enable lingering once:

```bash
sudo loginctl enable-linger "$USER"
systemctl --user restart codex-thing.service
systemctl --user status codex-thing.service --no-pager
journalctl --user -u codex-thing.service -n 100 --no-pager
```

### macOS service details

The installer creates
`~/Library/LaunchAgents/com.codex-thing.web.plist`. It starts automatically when
that user logs in. Inspect or restart it with:

```bash
launchctl print "gui/$UID/com.codex-thing.web"
launchctl kickstart -k "gui/$UID/com.codex-thing.web"
tail -n 100 "$CODEX_THING_DIR/codex-thing.log"
tail -n 100 "$CODEX_THING_DIR/codex-thing.error.log"
```

A LaunchAgent is a user-login service, which is the macOS equivalent appropriate
for a process that uses that user's Codex authentication.

## Environment-specific deployment: `WORKSTATION` to `SERVER`

The repository includes a deliberately isolated `SERVER` deployment wrapper. It
does not place the hostname in generic service code.

The validated `SERVER` environment is Arch Linux x86-64 with user `codex-user`,
passwordless sudo, a running systemd user manager with lingering enabled, Node,
npm, Go, and Codex on `PATH`. Its Codex CLI was older than the required version at
the time this runbook was written, so the first deployment must include the
explicit upgrade flag.

From the repository checkout on `WORKSTATION`, run:

```bash
cd /path/to/codex-thing
./scripts/deploy-SERVER.sh --upgrade-codex
```

That command performs the following bounded operations:

1. Connects to the SSH alias `SERVER` with batch authentication.
2. Creates `/opt/codex-thing` with sudo and gives it to the SSH user.
3. Uses `rsync` to make the release files match the checkout, excluding `.git`,
   local dependencies, builds, logs, and the remote `config.env`.
4. Upgrades the remote Codex CLI with
   `sudo npm install -g @openai/codex@latest` because the flag was supplied.
5. Builds the application remotely.
6. Installs and starts `~/.config/systemd/user/codex-thing.service`.
7. Installs managed wrapper blocks in `~/.zshrc` and `~/.bashrc`.

Subsequent deployments normally omit the upgrade flag:

```bash
./scripts/deploy-SERVER.sh
```

Verify from `WORKSTATION`:

```bash
ssh SERVER 'codex login status'
ssh SERVER 'systemctl --user status codex-thing.service --no-pager'
ssh SERVER 'curl --fail http://127.0.0.1:40001/api/health'
curl --fail http://SERVER:40001/api/health
```

If authentication is missing, authenticate as `codex-user` on `SERVER` and run the
deployment again. If the service logs report an expired refresh token even though
`codex login status` succeeds, reauthenticate or securely copy the active
`WORKSTATION` `auth.json` as described under Requirements, then run:

```bash
ssh SERVER 'systemctl --user restart codex-thing.service'
```

Do not use `--skip-auth-check` for a normal deployment.

The `SERVER` defaults are:

| Setting | Value |
| --- | --- |
| SSH host | `SERVER` |
| Install directory | `/opt/codex-thing` |
| Initial workspace | `/home/codex` |
| Web UI | `http://SERVER:40001` |
| Private app-server | `ws://127.0.0.1:40002` on `SERVER` |
| Shell wrappers | zsh and bash |

Override those values with `deploy-SERVER.sh --help`; for example,
`--workspace /home/codex/projects` narrows filesystem suggestions and the
initial workspace.

## Connecting terminal UIs

After restarting a shell on the server, plain `codex` uses the shared local
app-server because of the installed wrapper. `codex resume SESSION_ID` and the
interactive session picker do as well.

To connect a terminal UI from a different computer, tunnel the app-server rather
than exposing it. This example maps local port `41002` to `SERVER` port `40002`:

```bash
ssh -N -L 41002:127.0.0.1:40002 SERVER
```

In another terminal on that client, either call Codex explicitly:

```bash
codex --remote ws://127.0.0.1:41002
codex resume --remote ws://127.0.0.1:41002 SESSION_ID
```

or install/update the wrapper on the client checkout:

```bash
./scripts/install-shell-wrapper.sh \
  --endpoint ws://127.0.0.1:41002 \
  --shells zsh,bash
exec "$SHELL" -l
```

Only clients using the same app-server receive the same live turns and approval
state. A standalone `codex` process that bypasses the wrapper has its own runtime,
even if it resumes the same stored thread ID.

## Configuration

Re-run `scripts/install.sh` with the desired options to make persistent changes.
The installer rewrites `INSTALL_DIR/config.env` and restarts/enables the selected
service.

| Installer option | Runtime variable | Default |
| --- | --- | --- |
| `--port` | `PORT` | `40001` |
| `--workspace` | `CODEX_WORKSPACE` | Install directory |
| `--app-server-url` | `CODEX_APP_SERVER_URL` | `ws://127.0.0.1:40002` |
| `--bootstrap-threads` | `CODEX_BOOTSTRAP_THREADS` | Empty |
| `--model` | `CODEX_MODEL` | Local Codex default |
| — | `CODEX_BIN` | Absolute `codex` path found during install |
| — | `WEB_DIST` | `INSTALL_DIR/dist` |

`CODEX_BOOTSTRAP_THREADS` is a comma-separated list of stored thread IDs to
resume when the service starts and always include under Recent Sessions. Leave it
empty for normal discovery.

The app-server URL is restricted by the installer to loopback `ws://` addresses.
The Go bridge itself always listens on all IPs so browsers on trusted machines can
reach it.

## Updating

For a generic Git installation:

```bash
cd "$HOME/.local/share/codex-thing"
git pull --ff-only
./scripts/install.sh \
  --install-dir "$PWD" \
  --workspace "$HOME" \
  --service auto \
  --shells auto
exec "$SHELL" -l
```

For `SERVER`, run `./scripts/deploy-SERVER.sh` from `WORKSTATION`. The service is
restarted by the remote installer after the new build succeeds.

## Stopping or uninstalling

Stop without deleting files:

```bash
# Linux
systemctl --user disable --now codex-thing.service

# macOS
launchctl bootout "gui/$UID/com.codex-thing.web"
```

For a full uninstall, first stop the service, then remove its service definition:

```bash
# Linux
rm "$HOME/.config/systemd/user/codex-thing.service"
systemctl --user daemon-reload

# macOS
rm "$HOME/Library/LaunchAgents/com.codex-thing.web.plist"
```

Remove the blocks between `codex-thing managed wrapper` markers from `.zshrc`
and `.bashrc`, and remove
`~/.config/fish/conf.d/codex-thing.fish` if it exists. Restart the shell. Finally,
remove the installation directory only after confirming it contains no local
work or configuration that must be retained.

## Troubleshooting checklist

An installation agent should run these checks in order:

1. `node --version`, `npm --version`, `go version`, and `codex --version` satisfy
   the versions above.
2. `codex login status` succeeds as the service user.
3. `config.env` contains the expected absolute paths and loopback app-server URL.
4. `systemctl --user status codex-thing.service` or `launchctl print
   "gui/$UID/com.codex-thing.web"` reports a running process.
5. Service logs do not contain a Codex initialization or protocol error.
6. `curl --fail http://127.0.0.1:40001/api/health` succeeds on the server.
7. Port `40001` is reachable from the browser machine through the trusted network
   and allowed by the firewall.
8. Port `40002` is not remotely reachable.
9. The shell was restarted after wrapper installation.
10. `type codex` reports a function in an interactive wrapped shell, and
    `command codex --version` still reports the underlying CLI version.

If the UI loads but a terminal does not receive browser messages, the terminal
is not attached to the same app-server. Restart its shell and use plain `codex`,
or pass the exact `--remote` endpoint explicitly.
