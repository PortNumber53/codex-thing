#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 CONFIG_FILE SERVER_BINARY" >&2
  exit 2
fi

config_file=$1
server_binary=$2

if [[ ! -r "$config_file" ]]; then
  echo "configuration file is not readable: $config_file" >&2
  exit 1
fi
if [[ ! -x "$server_binary" ]]; then
  echo "server binary is not executable: $server_binary" >&2
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || ${line:0:1} == "#" ]] && continue
  if [[ "$line" != *=* ]]; then
    echo "invalid configuration line: $line" >&2
    exit 1
  fi
  key=${line%%=*}
  value=${line#*=}
  if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "invalid configuration key: $key" >&2
    exit 1
  fi
  export "$key=$value"
done < "$config_file"

exec "$server_binary"
