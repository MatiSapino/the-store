#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

inventory="$repo_root/ansible/inventory/hosts.yml"
playbook="$repo_root/ansible/site.yml"

if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  playbook="$1"
  shift
  if [[ "$playbook" != /* ]]; then
    playbook="$repo_root/$playbook"
  fi
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible-playbook is not available in this shell." >&2
  exit 1
fi

if [[ ! -f "$inventory" ]]; then
  echo "ERROR: inventory not found: $inventory" >&2
  exit 1
fi

if [[ ! -f "$playbook" ]]; then
  echo "ERROR: playbook not found: $playbook" >&2
  exit 1
fi

key_dir="$HOME/.vagrant.d"
key_file="$key_dir/insecure_private_key"

if [[ ! -f "$key_file" ]]; then
  win_home="${VAGRANT_WINDOWS_HOME:-}"

  if [[ -z "$win_home" ]] && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    win_profile="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')"
    win_home="$(wslpath "$win_profile" 2>/dev/null || true)"
  fi

  if [[ -z "$win_home" && "$repo_root" =~ ^/mnt/([a-zA-Z])/Users/([^/]+)/ ]]; then
    win_home="/mnt/${BASH_REMATCH[1]}/Users/${BASH_REMATCH[2]}"
  fi

  win_key="$win_home/.vagrant.d/insecure_private_key"

  if [[ -z "$win_home" || ! -f "$win_key" ]]; then
    echo "ERROR: Vagrant insecure key was not found in WSL or Windows." >&2
    echo "Set VAGRANT_WINDOWS_HOME, for example:" >&2
    echo "  VAGRANT_WINDOWS_HOME=/mnt/c/Users/EMINE bash scripts/ansible-wsl.sh" >&2
    exit 1
  fi

  mkdir -p "$key_dir"
  cp "$win_key" "$key_file"
fi

chmod 600 "$key_file"

for host in 192.168.56.10 192.168.56.11 192.168.56.12; do
  ssh-keygen -R "$host" >/dev/null 2>&1 || true
done

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
export ANSIBLE_RETRY_FILES_ENABLED="${ANSIBLE_RETRY_FILES_ENABLED:-False}"

echo "Running: ansible-playbook -i $inventory $playbook $*"
exec ansible-playbook -i "$inventory" "$playbook" "$@"
