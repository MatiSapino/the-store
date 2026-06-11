#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

UNAME_S="$(uname -s)"
KUBECONFIG_FILE="ansible/k3s.yaml"
NODE_NAME="worker3"

if [[ "$UNAME_S" == "Darwin" ]]; then
  PROVIDER="lima"
  INVENTORY="ansible/inventory/hosts-lima.yml"
else
  PROVIDER="vagrant"
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

comment_scale_block() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines(keepends=True)
changed = False

def split_ending(line):
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n"):
        return line[:-1], "\n"
    return line, ""

for idx, line in enumerate(lines):
    body, ending = split_ending(line)
    if "#scale#" in body or "worker3" not in body:
        continue

    match = re.match(r"^(\s*)(.*worker3.*)$", body)
    if not match:
        continue

    base_indent, rest = match.groups()
    lines[idx] = f"{base_indent}#scale# {rest}{ending}"
    changed = True

    # YAML inventory block: comment worker3 children until the block ends.
    if rest.strip() == "worker3:":
        base_len = len(base_indent)
        for child_idx in range(idx + 1, len(lines)):
            child_body, child_ending = split_ending(lines[child_idx])
            if not child_body.strip():
                break
            if child_body.lstrip().startswith("#scale#"):
                continue
            child_indent_len = len(child_body) - len(child_body.lstrip())
            if child_indent_len <= base_len:
                break
            lines[child_idx] = (
                f"{base_indent}#scale# {child_body[base_len:]}{child_ending}"
            )
        break

if changed:
    path.write_text("".join(lines))
    print(f"[OK]  comentado worker3 en {path}")
else:
    print(f"[OK]  {path} ya tenia worker3 comentado o no lo define")
PYEOF
}

remove_node_from_cluster() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "(kubectl no instalado: omito baja del nodo en Kubernetes)"
    return
  fi

  if [[ ! -f "$KUBECONFIG_FILE" ]]; then
    echo "(no existe $KUBECONFIG_FILE: omito baja del nodo en Kubernetes)"
    return
  fi

  if ! KUBECONFIG="$KUBECONFIG_FILE" kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
    echo "[OK]  $NODE_NAME no existe en Kubernetes"
    return
  fi

  echo "=== Drenando $NODE_NAME ==="
  if ! KUBECONFIG="$KUBECONFIG_FILE" kubectl drain "$NODE_NAME" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=120s; then
    echo "[!!] drain de $NODE_NAME fallo; intento borrar el nodo igual" >&2
  fi

  echo "=== Borrando $NODE_NAME del cluster ==="
  KUBECONFIG="$KUBECONFIG_FILE" kubectl delete node "$NODE_NAME" --ignore-not-found
}

destroy_worker_vm() {
  case "$PROVIDER" in
    vagrant)
      if ! command -v "$VAGRANT_CMD" >/dev/null 2>&1; then
        echo "ERROR: vagrant no esta instalado." >&2
        echo "       En Linux, corre 'bash scripts/setup-linux.sh'. En WSL, instala Vagrant en Windows y habilita WSL interop." >&2
        exit 1
      fi

      if "$VAGRANT_CMD" status "$NODE_NAME" >/dev/null 2>&1; then
        echo "=== $VAGRANT_CMD destroy -f $NODE_NAME ==="
        "$VAGRANT_CMD" destroy -f "$NODE_NAME"
      else
        echo "[OK]  $NODE_NAME no esta definido en Vagrant"
      fi
      ;;
    lima)
      if ! command -v limactl >/dev/null 2>&1; then
        echo "ERROR: limactl no esta instalado. Corre 'bash scripts/setup-mac.sh' y eligi opcion B." >&2
        exit 1
      fi

      echo "=== limactl delete --force $NODE_NAME ==="
      limactl delete --force "$NODE_NAME" 2>/dev/null || true
      ;;
  esac
}

remove_node_from_cluster
destroy_worker_vm

case "$PROVIDER" in
  vagrant)
    comment_scale_block Vagrantfile
    comment_scale_block "$INVENTORY"
    ;;
  lima)
    comment_scale_block "$INVENTORY"
    ;;
esac

echo "=== Estado del cluster despues del descale ==="
if command -v kubectl >/dev/null 2>&1 && [[ -f "$KUBECONFIG_FILE" ]]; then
  KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes || true
  if KUBECONFIG="$KUBECONFIG_FILE" kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
    echo "[!!] $NODE_NAME todavia aparece en el cluster" >&2
    exit 1
  fi
else
  echo "(kubectl no disponible o sin kubeconfig: omito verificacion)"
fi

echo "[OK]  descale terminado"
