#!/usr/bin/env bash
# Wrapper de ansible-playbook para macOS Apple Silicon (QEMU + socket_vmnet).
# Usa hosts-qemu.yml: Ansible conecta por localhost:5001x en vez de 192.168.56.x.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

inventory="$repo_root/ansible/inventory/hosts-qemu.yml"
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

key_file="$HOME/.vagrant.d/insecure_private_keys/vagrant.key.rsa"
if [[ ! -f "$key_file" ]]; then
  echo "ERROR: Vagrant insecure key not found at $key_file" >&2
  echo "Run 'vagrant up' at least once so Vagrant downloads the key." >&2
  exit 1
fi
chmod 600 "$HOME/.vagrant.d/insecure_private_keys/"*

# Clean up stale host keys for localhost ports used by the QEMU VMs
for port in 50010 50011 50012; do
  ssh-keygen -R "[127.0.0.1]:$port" >/dev/null 2>&1 || true
  ssh-keygen -R "[localhost]:$port"  >/dev/null 2>&1 || true
done

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
export ANSIBLE_RETRY_FILES_ENABLED="${ANSIBLE_RETRY_FILES_ENABLED:-False}"

echo "Running: ansible-playbook -i $inventory $playbook $*"
exec ansible-playbook -i "$inventory" "$playbook" "$@"
