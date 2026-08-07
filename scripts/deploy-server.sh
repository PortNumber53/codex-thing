#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

host=SERVER
remote_dir=/opt/codex-thing
remote_workspace=/home/codex
remote_shells=zsh,bash
upgrade_codex=false

usage() {
  cat <<'EOF'
Deploy this checkout from WORKSTATION to the environment-specific `SERVER` host.

Usage: scripts/deploy-SERVER.sh [options]

Options:
  --host HOST             SSH host (default: SERVER)
  --remote-dir PATH       Install directory (default: /opt/codex-thing)
  --workspace PATH        Initial Codex workspace (default: /home/codex)
  --shells LIST           Shell wrappers to install (default: zsh,bash)
  --upgrade-codex         Upgrade the remote Codex CLI with npm before installing
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host=${2:?--host requires a value}; shift 2 ;;
    --remote-dir) remote_dir=${2:?--remote-dir requires a value}; shift 2 ;;
    --workspace) remote_workspace=${2:?--workspace requires a value}; shift 2 ;;
    --shells) remote_shells=${2:?--shells requires a value}; shift 2 ;;
    --upgrade-codex) upgrade_codex=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$host" =~ ^[A-Za-z0-9._@-]+$ ]]; then
  echo "invalid SSH host: $host" >&2
  exit 2
fi
for path in "$remote_dir" "$remote_workspace"; do
  if [[ ! "$path" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "remote paths may only contain letters, digits, dot, underscore, slash, and dash: $path" >&2
    exit 2
  fi
done
if [[ "$remote_dir" == / || "$remote_dir" == /opt || "$remote_dir" == /home ]]; then
  echo "refusing unsafe --remote-dir: $remote_dir" >&2
  exit 2
fi
if [[ ! "$remote_shells" =~ ^(none|auto|[a-z]+(,[a-z]+)*)$ ]]; then
  echo "invalid --shells value: $remote_shells" >&2
  exit 2
fi

remote_user=$(ssh -o BatchMode=yes "$host" 'id -un')
echo "Preparing $host:$remote_dir for $remote_user..."
ssh -o BatchMode=yes "$host" "sudo install -d -o '$remote_user' -g '$remote_user' '$remote_dir'"

echo "Synchronizing release files..."
rsync -az --delete-delay \
  --exclude .git/ \
  --exclude node_modules/ \
  --exclude dist/ \
  --exclude bin/ \
  --exclude config.env \
  --exclude '*.log' \
  "$repo_root/" "$host:$remote_dir/"

if [[ "$upgrade_codex" == true ]]; then
  echo "Upgrading Codex CLI on $host..."
  ssh -o BatchMode=yes "$host" 'sudo npm install -g @openai/codex@latest'
fi

echo "Building and installing the user service on $host..."
ssh -o BatchMode=yes "$host" \
  "'$remote_dir/scripts/install.sh' --install-dir '$remote_dir' --workspace '$remote_workspace' --service systemd-user --shells '$remote_shells'"

echo "Verifying the remote service..."
ssh -o BatchMode=yes "$host" '
  for attempt in {1..20}; do
    if systemctl --user is-active --quiet codex-thing.service &&
       curl --fail --silent http://127.0.0.1:40001/api/health; then
      exit 0
    fi
    sleep 1
  done
  echo "codex-thing did not become healthy within 20 seconds" >&2
  systemctl --user status codex-thing.service --no-pager >&2 || true
  exit 1
'
echo

echo
echo "Deployment complete: http://$host:40001"
echo "The app-server remains private at ws://127.0.0.1:40002 on $host."
echo "Restart shells on $host before plain 'codex' uses the shared app-server."
