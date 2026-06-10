#!/usr/bin/env bash
# Wrapper for ansible-playbook using the Lima VM inventory.
# Usage:
#   bash scripts/ansible-lima.sh                          # runs site.yml
#   bash scripts/ansible-lima.sh ansible/playbooks/02-install-control-plane.yml
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

inventory="$repo_root/ansible/inventory/hosts-lima.yml"
playbook="$repo_root/ansible/site.yml"

if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  playbook="$1"
  shift
  if [[ "$playbook" != /* ]]; then
    playbook="$repo_root/$playbook"
  fi
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible-playbook not found. Run: bash scripts/setup-mac.sh" >&2
  exit 1
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "ERROR: limactl not found. Install Lima: brew install lima" >&2
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

# Verify VMs are running
for vm in cp worker1 worker2; do
  state="$(limactl list --format json 2>/dev/null \
    | python3 -c "import sys,json; vms={v['name']:v['status'] for v in json.load(sys.stdin)}; print(vms.get('$vm','missing'))" 2>/dev/null || echo 'missing')"
  if [[ "$state" != "Running" ]]; then
    echo "WARNING: Lima VM '$vm' is not running (status: $state)." >&2
    echo "         Run: bash scripts/lima-up.sh" >&2
  fi
done

# Clean up stale host keys for Lima SSH ports
for port in 60010 60011 60012 60013; do
  ssh-keygen -R "[127.0.0.1]:$port" >/dev/null 2>&1 || true
  ssh-keygen -R "[localhost]:$port"  >/dev/null 2>&1 || true
done

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
export ANSIBLE_RETRY_FILES_ENABLED="${ANSIBLE_RETRY_FILES_ENABLED:-False}"

echo "Running: ansible-playbook -i $inventory $playbook $*"
exec ansible-playbook -i "$inventory" "$playbook" "$@"
