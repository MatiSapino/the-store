#!/usr/bin/env bash
# Start all Lima VMs and auto-update hosts-lima.yml with their real IPs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMA_DIR="$REPO_ROOT/lima"
INVENTORY="$REPO_ROOT/ansible/inventory/hosts-lima.yml"

start_vm() {
  local name="$1"
  local config="$LIMA_DIR/${name}.yaml"
  # limactl list columns: NAME STATUS SSH VMTYPE ...
  local status
  status="$(limactl list 2>/dev/null | awk -v n="$name" '$1==n{print $2}' || echo '')"
  case "$status" in
    Running) echo "[OK]  $name already running" ;;
    '')      echo "[..] Creating $name..."; limactl start --tty=false --name="$name" "$config"; echo "[OK]  $name started" ;;
    *)       echo "[..] Starting $name (was: $status)..."; limactl start --tty=false "$name"; echo "[OK]  $name started" ;;
  esac
}

get_ip() {
  local name="$1"
  # lima0 is the socket_vmnet shared interface — unique IP per VM, reachable by all nodes.
  # eth0 is vzNAT (same IP on every VM, isolated), so we must not use it.
  limactl shell "$name" ip -4 addr show lima0 2>/dev/null \
    | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | awk '{print $2}' \
    | head -1 || true
}

wait_for_ip() {
  local name="$1" ip="" i=0
  while [[ $i -lt 12 ]]; do
    ip="$(get_ip "$name")"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    i=$((i + 1))
    echo "[..] Waiting for $name to get an IP ($i/12)..."
    sleep 5
  done
  echo ""
  return 1
}

echo "=== Bringing up Lima VMs ==="
start_vm cp
start_vm worker1
start_vm worker2

echo ""
echo "=== Discovering VM IPs ==="
CP_IP="$(wait_for_ip cp)"
W1_IP="$(wait_for_ip worker1)"
W2_IP="$(wait_for_ip worker2)"

for vm_name in cp worker1 worker2; do
  case "$vm_name" in
    cp)      ip_val="$CP_IP" ;;
    worker1) ip_val="$W1_IP" ;;
    worker2) ip_val="$W2_IP" ;;
    *)       ip_val="" ;;
  esac
  if [[ -z "$ip_val" ]]; then
    echo "[!!] Could not detect IP for $vm_name"
    echo "     Debug: limactl shell $vm_name ip -4 addr"
    exit 1
  fi
  echo "[OK]  $vm_name -> $ip_val"
done

# The host is reachable at the socket_vmnet gateway IP (lima0 default route).
# This is the only address that is reachable from ALL VMs (vzNAT is per-VM isolated).
GW="$(limactl shell cp ip -4 route show dev lima0 2>/dev/null | awk '/default/{print $3}' | head -1 || echo '')"
[[ -z "$GW" ]] && GW="192.168.56.1"  # fallback: socket_vmnet shared gateway
echo "[OK]  host (registry_host) -> $GW"

echo ""
echo "=== Updating $INVENTORY ==="
python3 - "$INVENTORY" "$CP_IP" "$W1_IP" "$W2_IP" "$GW" <<'PYEOF'
import sys, re

inv_file, cp_ip, w1_ip, w2_ip, gw = sys.argv[1:]
ip_map = {"cp": cp_ip, "worker1": w1_ip, "worker2": w2_ip}

with open(inv_file) as f:
    lines = f.readlines()

out = []
current_host = None
for line in lines:
    stripped = line.lstrip()
    # Detect a host-name key: "cp:", "worker1:", "worker2:" (not a comment)
    m = re.match(r'^(\s+)(cp|worker1|worker2):\s*(?:#.*)?$', line)
    if m and not stripped.startswith('#'):
        current_host = m.group(2)

    # Update k3s_node_ip for the current host
    if current_host and re.match(r'\s+k3s_node_ip:\s+', line):
        line = re.sub(r'(k3s_node_ip:\s+)[\d.]+', r'\g<1>' + ip_map[current_host], line)
        current_host = None

    # Uncomment / update registry_host in the vars section
    if gw:
        if re.match(r'\s+#\s*registry_host:', line):
            indent = ' ' * (len(line) - len(line.lstrip()))
            line = indent + 'registry_host: "' + gw + '"\n'
        elif re.match(r'\s+registry_host:', line):
            line = re.sub(r'(registry_host:\s+)["\']?[\d.]+["\']?', r'\g<1>"' + gw + '"', line)

    out.append(line)

with open(inv_file, 'w') as f:
    f.writelines(out)

print("  cp=%s  worker1=%s  worker2=%s  registry_host=%s" % (cp_ip, w1_ip, w2_ip, gw or '(not updated)'))
PYEOF

echo ""
echo "=== All VMs up. Run: make deploy ==="
