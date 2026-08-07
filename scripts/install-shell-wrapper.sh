#!/usr/bin/env bash
set -euo pipefail

endpoint="ws://127.0.0.1:40002"
shells="auto"

usage() {
  cat <<'EOF'
Install a managed shell function that routes interactive Codex sessions through
the shared app-server while leaving administrative and non-interactive commands
on the normal local CLI path.

Usage: scripts/install-shell-wrapper.sh [options]

Options:
  --endpoint URL       Shared Codex app-server URL (default: ws://127.0.0.1:40002)
  --shells LIST        auto, none, or comma-separated zsh,bash,fish (default: auto)
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      endpoint=${2:?--endpoint requires a value}
      shift 2
      ;;
    --shells)
      shells=${2:?--shells requires a value}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$endpoint" != ws://* && "$endpoint" != wss://* ]]; then
  echo "--endpoint must start with ws:// or wss://" >&2
  exit 2
fi
if [[ "$endpoint" == *$'\n'* || "$endpoint" == *"'"* ]]; then
  echo "--endpoint contains unsupported characters" >&2
  exit 2
fi

if [[ "$shells" == "none" ]]; then
  echo "Shell wrapper installation skipped."
  exit 0
fi

if [[ "$shells" == "auto" ]]; then
  detected=()
  [[ ${SHELL:-} == */zsh || -f "$HOME/.zshrc" ]] && detected+=(zsh)
  [[ ${SHELL:-} == */bash || -f "$HOME/.bashrc" ]] && detected+=(bash)
  command -v fish >/dev/null 2>&1 && detected+=(fish)
  if [[ ${#detected[@]} -eq 0 ]]; then
    case "$(basename "${SHELL:-sh}")" in
      zsh) detected=(zsh) ;;
      bash) detected=(bash) ;;
      fish) detected=(fish) ;;
      *)
        echo "Could not detect zsh, bash, or fish; use --shells explicitly." >&2
        exit 1
        ;;
    esac
  fi
  shells=$(IFS=,; echo "${detected[*]}")
fi

begin_marker="# >>> codex-thing managed wrapper >>>"
end_marker="# <<< codex-thing managed wrapper <<<"

install_posix_wrapper() {
  local rc_file=$1
  local tmp_file
  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/codex-thing-rc.XXXXXX")
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$rc_file" > "$tmp_file"
  while [[ -s "$tmp_file" && $(tail -c 1 "$tmp_file" | wc -l | tr -d ' ') -eq 0 ]]; do
    printf '\n' >> "$tmp_file"
  done
  cat >> "$tmp_file" <<EOF
$begin_marker
codex() {
  local codex_subcommand="\${1:-}"
  case "\$codex_subcommand" in
    login|logout|auth)
      local codex_auth_action="\$codex_subcommand"
      if [[ "\$codex_subcommand" == "auth" ]]; then
        codex_auth_action="\${2:-}"
      fi
      command codex "\$@"
      local codex_auth_status=\$?
      if [[ \$codex_auth_status -eq 0 && ( "\$codex_auth_action" == "login" || "\$codex_auth_action" == "logout" ) ]]; then
        local codex_auth_home="\${CODEX_HOME:-\$HOME/.codex}"
        mkdir -p "\$codex_auth_home" 2>/dev/null || true
        touch "\$codex_auth_home/.auth-changed" 2>/dev/null || true
      fi
      return "\$codex_auth_status"
      ;;
    exec|review|mcp|plugin|mcp-server|app-server|remote-control|app|completion|update|doctor|sandbox|debug|apply|cloud|exec-server|features|help)
      command codex "\$@"
      ;;
    *)
      command codex --remote '$endpoint' "\$@"
      ;;
  esac
}
$end_marker
EOF
  mv "$tmp_file" "$rc_file"
  echo "Installed Codex wrapper in $rc_file"
}

install_fish_wrapper() {
  local fish_file="$HOME/.config/fish/conf.d/codex-thing.fish"
  mkdir -p "$(dirname "$fish_file")"
  cat > "$fish_file" <<EOF
# Managed by codex-thing. Re-run install-shell-wrapper.sh to change it.
function codex
    set -l codex_subcommand \$argv[1]
    switch \$codex_subcommand
        case login logout auth
            set -l codex_auth_action \$codex_subcommand
            if test "\$codex_subcommand" = auth
                set codex_auth_action \$argv[2]
            end
            command codex \$argv
            set -l codex_auth_status \$status
            if test \$codex_auth_status -eq 0; and contains -- "\$codex_auth_action" login logout
                set -l codex_auth_home \$CODEX_HOME
                if test -z "\$codex_auth_home"
                    set codex_auth_home \$HOME/.codex
                end
                mkdir -p "\$codex_auth_home" 2>/dev/null; or true
                touch "\$codex_auth_home/.auth-changed" 2>/dev/null; or true
            end
            return \$codex_auth_status
        case exec review mcp plugin mcp-server app-server remote-control app completion update doctor sandbox debug apply cloud exec-server features help
            command codex \$argv
        case '*'
            command codex --remote '$endpoint' \$argv
    end
end
EOF
  echo "Installed Codex wrapper in $fish_file"
}

IFS=',' read -r -a requested_shells <<< "$shells"
for requested_shell in "${requested_shells[@]}"; do
  case "$requested_shell" in
    zsh) install_posix_wrapper "$HOME/.zshrc" ;;
    bash) install_posix_wrapper "$HOME/.bashrc" ;;
    fish) install_fish_wrapper ;;
    *)
      echo "unsupported shell in --shells: $requested_shell" >&2
      exit 2
      ;;
  esac
done

echo
echo "Restart every open shell before using plain 'codex'."
echo "For the current shell, run: exec \"\$SHELL\" -l"
