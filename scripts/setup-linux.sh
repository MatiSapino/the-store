#!/usr/bin/env bash
# Install all prerequisites for Linux (Ubuntu/Debian) and WSL2.
# Run once before doing anything else: bash scripts/setup-linux.sh
set -euo pipefail

ok()   { echo "[OK]  $*"; }
info() { echo "[..] $*"; }
warn() { echo "[!!] $*"; }

IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=true
fi

if [[ "$IS_WSL" == "true" ]]; then
  echo "=== WSL2 detected ==="
  echo "VMs run on the Windows host via VirtualBox."
  echo "This script installs Ansible + Docker tools inside WSL2."
  echo ""
else
  echo "=== Native Linux detected ==="
fi

# ── Pre-flight checks (Linux nativo) ───────────────────────────────────────────
if [[ "$IS_WSL" == "false" ]]; then
  # BIND9 / named escuchando en :53 sobre cualquier interfaz (no solo el stub de
  # systemd-resolved). Si está, vagrant-libvirt no puede arrancar su dnsmasq
  # cuando aparece virbr1 con 192.168.121.1 → falla con "Address already in use".
  if command -v ss >/dev/null 2>&1 && \
     sudo ss -lntup 2>/dev/null | grep -E '\bnamed\b.*:53\b' >/dev/null; then
    warn "BIND9 (named) esta escuchando en :53. Va a chocar con vagrant-libvirt."
    warn "Solucion temporal: sudo systemctl stop bind9   (o named)"
    warn "Restaurar despues con: sudo systemctl start bind9"
  fi

  # vboxnet0 viejo con 192.168.56.0/24 ocupado choca con la red privada de
  # libvirt 'the-store0' que usa la misma subred.
  if ip -br a 2>/dev/null | grep -E '^vboxnet0\b.*192\.168\.56\.' >/dev/null; then
    warn "vboxnet0 tiene 192.168.56.x asignado. Va a chocar con la red de libvirt."
    warn "Solucion: sudo ip link set vboxnet0 down"
  fi
fi

# ── System packages ────────────────────────────────────────────────────────────
info "Updating apt..."
sudo apt-get update -qq

info "Installing base packages..."
sudo apt-get install -y -qq \
  curl wget git python3 python3-pip pipx \
  ca-certificates gnupg lsb-release apt-transport-https

# ── Ansible ────────────────────────────────────────────────────────────────────
if command -v ansible-playbook >/dev/null 2>&1; then
  ok "ansible already installed ($(ansible --version | head -1))"
else
  info "Installing Ansible via pipx..."
  pipx install ansible-core
  pipx inject ansible-core jinja2
  # Add pipx bin dir to PATH in this session
  export PATH="$PATH:$HOME/.local/bin"
  ok "ansible installed"
fi

# ── Docker ─────────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  ok "docker already installed"
else
  info "Installing Docker Engine..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  sudo usermod -aG docker "$USER"
  ok "Docker installed. Log out and back in (or run: newgrp docker)"
fi

# ── kubectl ────────────────────────────────────────────────────────────────────
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl already installed"
else
  info "Installing kubectl..."
  curl -fsSL "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  ok "kubectl installed"
fi

# ── VM backend (native Linux only) ────────────────────────────────────────────
if [[ "$IS_WSL" == "false" ]]; then
  echo ""
  echo "Choose VM backend:"
  echo "  A) libvirt + KVM (recommended for Linux)"
  echo "  B) VirtualBox"
  read -rp "Choice [A/b]: " vm_choice
  vm_choice="${vm_choice:-A}"

  if [[ "${vm_choice^^}" == "A" ]]; then
    info "Installing KVM + libvirt..."
    sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
      bridge-utils virtinst virt-manager
    sudo adduser "$USER" libvirt
    sudo adduser "$USER" kvm

    # Vagrant + libvirt
    if ! command -v vagrant >/dev/null 2>&1; then
      info "Installing Vagrant..."
      wget -O /tmp/vagrant.deb \
        "https://releases.hashicorp.com/vagrant/2.4.1/vagrant_2.4.1-1_amd64.deb"
      sudo dpkg -i /tmp/vagrant.deb
    fi

    if vagrant plugin list 2>/dev/null | grep -q vagrant-libvirt; then
      ok "vagrant-libvirt already installed"
    else
      info "Installing vagrant-libvirt plugin..."
      sudo apt-get install -y ruby-dev libvirt-dev
      vagrant plugin install vagrant-libvirt
    fi
    ok "libvirt backend ready."

    if ! grep -q 'VAGRANT_DEFAULT_PROVIDER=libvirt' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export VAGRANT_DEFAULT_PROVIDER=libvirt' >> "$HOME/.bashrc"
      ok "Agregado 'export VAGRANT_DEFAULT_PROVIDER=libvirt' a ~/.bashrc"
      warn "Hace 'source ~/.bashrc' o abri una shell nueva antes de 'make up'"
    else
      ok "VAGRANT_DEFAULT_PROVIDER=libvirt ya estaba en ~/.bashrc"
    fi

  else
    info "Installing VirtualBox..."
    sudo apt-get install -y virtualbox virtualbox-ext-pack

    if ! command -v vagrant >/dev/null 2>&1; then
      info "Installing Vagrant..."
      wget -O /tmp/vagrant.deb \
        "https://releases.hashicorp.com/vagrant/2.4.1/vagrant_2.4.1-1_amd64.deb"
      sudo dpkg -i /tmp/vagrant.deb
    fi

    ok "VirtualBox backend ready. Use: vagrant up"
  fi

else
  # WSL2: Vagrant is on the Windows side, not in WSL
  echo ""
  info "WSL2: Vagrant + VirtualBox must be installed on the WINDOWS host."
  warn "This script does not install them. See scripts/setup-windows.ps1."
  echo ""
  echo "After VMs are up on Windows, run Ansible from WSL2 with:"
  echo "  bash scripts/ansible-wsl.sh ansible/site.yml"
fi

# ── Ansible collections ────────────────────────────────────────────────────────
echo ""
info "Installing Ansible collections..."
(cd "$(dirname "$0")/.." && ansible-galaxy collection install -r ansible/requirements.yml --force)
ok "Ansible collections installed"

echo ""
echo "=== Setup complete ==="
if [[ "$IS_WSL" == "false" ]]; then
  echo "If you just added yourself to the docker/libvirt/kvm groups,"
  echo "log out and back in before running vagrant up."
fi
