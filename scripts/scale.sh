#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

UNAME_S="$(uname -s)"

if [[ "$UNAME_S" == "Darwin" ]]; then
  PROVIDER="lima"
  ANSIBLE_SCRIPT="scripts/ansible-lima.sh"
  INVENTORY="ansible/inventory/hosts-lima.yml"
else
  PROVIDER="vagrant"
  ANSIBLE_SCRIPT="scripts/ansible-wsl.sh"
  INVENTORY="ansible/inventory/hosts.yml"
  if command -v vagrant >/dev/null 2>&1; then
    VAGRANT_CMD="vagrant"
  elif command -v vagrant.exe >/dev/null 2>&1; then
    VAGRANT_CMD="vagrant.exe"
  else
    VAGRANT_CMD="vagrant"
  fi
fi

echo "=== Platform: $UNAME_S -> provider=$PROVIDER inventory=$INVENTORY ==="

case "$PROVIDER" in
  vagrant)
    if ! command -v "$VAGRANT_CMD" >/dev/null 2>&1; then
      echo "ERROR: vagrant no esta instalado." >&2
      echo "       En Linux, corre 'bash scripts/setup-linux.sh'. En WSL, instala Vagrant en Windows y habilita WSL interop." >&2
      exit 1
    fi
    ;;
  lima)
    if ! command -v limactl >/dev/null 2>&1; then
      echo "ERROR: limactl no esta instalado. Corre 'bash scripts/setup-mac.sh' y eligi opcion B." >&2
      exit 1
    fi
    ;;
esac

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible no esta instalado. Corre 'bash scripts/setup-linux.sh' (o el setup-* de tu SO)." >&2
  exit 1
fi

get_lima_ip() {
  local name="$1"
  limactl shell "$name" ip -4 addr show lima0 2>/dev/null \
    | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | awk '{print $2}' \
    | head -1 || true
}

wait_for_lima_ip() {
  local name="$1" ip="" i=0
  while [[ $i -lt 12 ]]; do
    ip="$(get_lima_ip "$name")"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    i=$((i + 1))
    echo "[..] Esperando IP lima0 para $name ($i/12)..." >&2
    sleep 5
  done
  echo ""
  return 1
}

get_lima_gateway() {
  limactl shell cp ip -4 route show dev lima0 2>/dev/null \
    | awk '/default/{print $3}' \
    | head -1 || true
}

uncomment_scale() {
  local file="$1"
  if grep -q '^[[:space:]]*#scale# ' "$file"; then
    sed -i.scale-bak -e 's/^\([[:space:]]*\)#scale# /\1/g' "$file"
    rm -f "$file.scale-bak"
    echo "[OK]  destapado worker3 en $file"
  else
    echo "[OK]  $file ya tiene worker3 destapado"
  fi
}

case "$PROVIDER" in
  vagrant)
    uncomment_scale Vagrantfile
    uncomment_scale "$INVENTORY"
    echo "=== $VAGRANT_CMD up worker3 ==="
    "$VAGRANT_CMD" up worker3
    # vagrant marca la VM como ready cuando eth0 (red default) acepta SSH,
    # pero eth1 (red privada the-store0, 192.168.56.0/24) la trae cloud-init
    # despues. Esperar a 192.168.56.13:22 evita la race con Ansible.
    echo "=== Esperando a que 192.168.56.13 (eth1) acepte SSH ==="
    for _ in {1..60}; do
      if (echo > /dev/tcp/192.168.56.13/22) 2>/dev/null; then
        echo "[OK]  eth1 lista para SSH"
        break
      fi
      sleep 2
    done
    if ! (echo > /dev/tcp/192.168.56.13/22) 2>/dev/null; then
      echo "[!!] 192.168.56.13:22 no responde despues de 120s" >&2
      exit 1
    fi
    ;;
  lima)
    uncomment_scale "$INVENTORY"
    state="$(limactl list 2>/dev/null | awk '$1=="worker3"{print $2}' || true)"
    if [[ "$state" != "Running" ]]; then
      echo "=== limactl start worker3 ==="
      limactl start --tty=false --name=worker3 lima/worker3.yaml
    else
      echo "[OK]  worker3 ya estaba Running"
    fi
    W3_IP="$(wait_for_lima_ip worker3 || true)"
    if [[ -z "$W3_IP" ]]; then
      echo "[!!] No pude obtener la IP lima0 de worker3" >&2
      exit 1
    fi
    GW="$(get_lima_gateway)"
    [[ -z "$GW" ]] && GW="192.168.56.1"
    python3 - "$INVENTORY" "$W3_IP" "$GW" <<'PYEOF'
import re, sys
inv, ip, gw = sys.argv[1], sys.argv[2], sys.argv[3]
with open(inv) as f: src = f.read()
src = re.sub(r'(worker3:[\s\S]*?k3s_node_ip:\s+)[\d.]+', r'\g<1>' + ip, src)
src = re.sub(r'(registry_host:\s+)["\']?[\d.]+["\']?', r'\g<1>"' + gw + '"', src)
open(inv, 'w').write(src)
print(f"[OK]  worker3 -> {ip}; registry_host -> {gw} en {inv}")
PYEOF
    ;;
esac

echo "=== Estado del cluster antes del join ==="
KUBECONFIG=ansible/k3s.yaml kubectl get nodes 2>/dev/null || echo "(kubectl no disponible o sin kubeconfig todavia)"

echo "=== Play 01: preparar worker3 ==="
bash "$ANSIBLE_SCRIPT" ansible/playbooks/01-prepare-nodes.yml --limit worker3

echo "=== Play 03: unir worker3 al cluster ==="
bash "$ANSIBLE_SCRIPT" ansible/playbooks/03-join-workers.yml --limit worker3

echo "=== Estado del cluster despues del join ==="
if ! command -v kubectl >/dev/null 2>&1; then
  echo "(kubectl no instalado: omito verificacion)"
  exit 0
fi

KUBECONFIG=ansible/k3s.yaml kubectl get nodes
if KUBECONFIG=ansible/k3s.yaml kubectl get node worker3 --no-headers 2>/dev/null | grep -qw Ready; then
  echo "[OK]  worker3 esta Ready en el cluster"
else
  echo "[!!] worker3 no aparece Ready" >&2
  exit 1
fi
