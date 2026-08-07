#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

install_dir=$repo_root
workspace=""
port=40001
app_server_url="ws://127.0.0.1:40002"
bootstrap_threads=""
model=""
service=auto
shells=auto
skip_auth_check=false
minimum_codex_version="0.146.1"

usage() {
  cat <<EOF
Build and install Codex Local Web for the current user.

Usage: scripts/install.sh [options]

Options:
  --install-dir PATH       Repository/install path (default: $repo_root)
  --workspace PATH         Initial workspace exposed to Codex (default: install path)
  --port PORT              Web listener port (default: 40001)
  --app-server-url URL     Private Codex app-server endpoint
                           (default: ws://127.0.0.1:40002)
  --bootstrap-threads IDS  Comma-separated thread IDs to resume at startup
  --model MODEL            Optional Codex model override
  --service TYPE           auto, systemd-user, launchd, or none (default: auto)
  --shells LIST            auto, none, or comma-separated zsh,bash,fish
  --skip-auth-check        Do not require 'codex login status' to succeed
  --minimum-codex VERSION  Required Codex CLI version (default: $minimum_codex_version)
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) install_dir=${2:?--install-dir requires a value}; shift 2 ;;
    --workspace) workspace=${2:?--workspace requires a value}; shift 2 ;;
    --port) port=${2:?--port requires a value}; shift 2 ;;
    --app-server-url) app_server_url=${2:?--app-server-url requires a value}; shift 2 ;;
    --bootstrap-threads) bootstrap_threads=${2:?--bootstrap-threads requires a value}; shift 2 ;;
    --model) model=${2:?--model requires a value}; shift 2 ;;
    --service) service=${2:?--service requires a value}; shift 2 ;;
    --shells) shells=${2:?--shells requires a value}; shift 2 ;;
    --skip-auth-check) skip_auth_check=true; shift ;;
    --minimum-codex) minimum_codex_version=${2:?--minimum-codex requires a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$workspace" ]]; then
  workspace=$install_dir
fi

if [[ "$install_dir" != /* || "$workspace" != /* ]]; then
  echo "--install-dir and --workspace must be absolute paths" >&2
  exit 2
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "--port must be an integer from 1 through 65535" >&2
  exit 2
fi
if [[ "$app_server_url" != ws://127.0.0.1:* && "$app_server_url" != ws://localhost:* ]]; then
  echo "Refusing a non-loopback app-server URL. Use ws://127.0.0.1:PORT or ws://localhost:PORT." >&2
  exit 2
fi
for value in "$install_dir" "$workspace" "$app_server_url" "$bootstrap_threads" "$model"; do
  if [[ "$value" == *$'\n'* ]]; then
    echo "configuration values cannot contain newlines" >&2
    exit 2
  fi
done
if [[ ! -f "$install_dir/package.json" || ! -f "$install_dir/server/go.mod" ]]; then
  echo "$install_dir is not a codex-thing checkout" >&2
  exit 1
fi
if [[ ! -d "$workspace" ]]; then
  echo "workspace does not exist: $workspace" >&2
  exit 1
fi

version_at_least() {
  local actual=${1#v}
  local required=${2#v}
  actual=${actual#go}
  required=${required#go}
  local actual_major=0 actual_minor=0 actual_patch=0
  local required_major=0 required_minor=0 required_patch=0
  if [[ ! "$actual" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([^0-9].*)?$ ]] ||
     [[ ! "$required" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([^0-9].*)?$ ]]; then
    return 1
  fi
  IFS=. read -r actual_major actual_minor actual_patch _ <<< "$actual"
  IFS=. read -r required_major required_minor required_patch _ <<< "$required"
  actual_patch=${actual_patch%%[^0-9]*}
  required_patch=${required_patch%%[^0-9]*}
  (( 10#$actual_major > 10#$required_major )) && return 0
  (( 10#$actual_major < 10#$required_major )) && return 1
  (( 10#$actual_minor > 10#$required_minor )) && return 0
  (( 10#$actual_minor < 10#$required_minor )) && return 1
  (( 10#${actual_patch:-0} >= 10#${required_patch:-0} ))
}

require_version() {
  local label=$1 actual=$2 required=$3
  if ! version_at_least "$actual" "$required"; then
    echo "$label $required or newer is required; found $actual" >&2
    exit 1
  fi
}

for command_name in node npm go codex; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required command is missing: $command_name" >&2
    exit 1
  fi
done

node_version=$(node --version)
go_version=$(go version | awk '{print $3}')
codex_version=$(codex --version | awk '{print $NF}')
require_version "Node" "$node_version" "20.0.0"
require_version "Go" "$go_version" "1.23.0"
require_version "Codex CLI" "$codex_version" "$minimum_codex_version"

if [[ "$skip_auth_check" != true ]] && ! codex login status >/dev/null 2>&1; then
  echo "Codex is not authenticated for user $USER. Run 'codex login --device-auth', then retry." >&2
  exit 1
fi

codex_bin=$(command -v codex)
mkdir -p "$install_dir/bin"

echo "Installing JavaScript dependencies..."
(cd "$install_dir" && npm ci)
echo "Building Vite assets..."
(cd "$install_dir" && npm run build)
echo "Building Go server..."
(cd "$install_dir" && go -C server build -o "$install_dir/bin/codex-thing-server" .)

config_file="$install_dir/config.env"
{
  printf '# Generated by scripts/install.sh. Re-run the installer to edit.\n'
  printf 'PORT=%s\n' "$port"
  printf 'CODEX_BIN=%s\n' "$codex_bin"
  printf 'CODEX_APP_SERVER_URL=%s\n' "$app_server_url"
  printf 'CODEX_WORKSPACE=%s\n' "$workspace"
  printf 'CODEX_BOOTSTRAP_THREADS=%s\n' "$bootstrap_threads"
  printf 'CODEX_MODEL=%s\n' "$model"
  printf 'WEB_DIST=%s\n' "$install_dir/dist"
} > "$config_file"
chmod 600 "$config_file"

if [[ "$service" == auto ]]; then
  case "$(uname -s)" in
    Linux) service=systemd-user ;;
    Darwin) service=launchd ;;
    *) service=none ;;
  esac
fi

case "$service" in
  systemd-user)
    if ! command -v systemctl >/dev/null 2>&1; then
      echo "systemctl is required for --service systemd-user" >&2
      exit 1
    fi
    if [[ "$install_dir" == *%* ]]; then
      echo "systemd install paths cannot contain '%'" >&2
      exit 2
    fi
    unit_dir="$HOME/.config/systemd/user"
    unit_file="$unit_dir/codex-thing.service"
    mkdir -p "$unit_dir"
    cat > "$unit_file" <<EOF
[Unit]
Description=Codex Local Web bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$install_dir
ExecStart="$install_dir/scripts/run-server.sh" "$config_file" "$install_dir/bin/codex-thing-server"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable codex-thing.service
    systemctl --user restart codex-thing.service
    echo "Installed and started user service: $unit_file"
    if command -v loginctl >/dev/null 2>&1 && [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true) != yes ]]; then
      echo "WARNING: enable boot startup with: sudo loginctl enable-linger '$USER'"
    fi
    ;;
  launchd)
    if [[ $(uname -s) != Darwin ]]; then
      echo "--service launchd is only supported on macOS" >&2
      exit 1
    fi
    for value in "$install_dir" "$config_file"; do
      if [[ "$value" == *['&<>']* ]]; then
        echo "launchd paths cannot contain &, <, or >" >&2
        exit 2
      fi
    done
    agent_dir="$HOME/Library/LaunchAgents"
    agent_file="$agent_dir/com.codex-thing.web.plist"
    mkdir -p "$agent_dir"
    cat > "$agent_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.codex-thing.web</string>
  <key>ProgramArguments</key>
  <array>
    <string>$install_dir/scripts/run-server.sh</string>
    <string>$config_file</string>
    <string>$install_dir/bin/codex-thing-server</string>
  </array>
  <key>WorkingDirectory</key><string>$install_dir</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$install_dir/codex-thing.log</string>
  <key>StandardErrorPath</key><string>$install_dir/codex-thing.error.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$UID/com.codex-thing.web" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$agent_file"
    launchctl kickstart -k "gui/$UID/com.codex-thing.web"
    echo "Installed and started LaunchAgent: $agent_file"
    ;;
  none)
    echo "Service installation skipped."
    ;;
  *)
    echo "unsupported --service value: $service" >&2
    exit 2
    ;;
esac

"$install_dir/scripts/install-shell-wrapper.sh" --endpoint "$app_server_url" --shells "$shells"

echo
echo "Installation complete."
echo "Web UI: http://$(uname -n):$port"
echo "Health check: curl --fail http://127.0.0.1:$port/api/health"
if [[ "$shells" != none ]]; then
  echo "REQUIRED: restart every open shell, or run: exec \"\$SHELL\" -l"
fi
