#!/usr/bin/env bash
# Install all prerequisites for macOS (Apple Silicon and Intel).
# Run once before doing anything else: bash scripts/setup-mac.sh
set -euo pipefail

ARCH="$(uname -m)"

# ── Helpers ────────────────────────────────────────────────────────────────────
ok()   { echo "[OK]  $*"; }
info() { echo "[..] $*"; }
warn() { echo "[!!] $*"; }

require_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found. Install it from https://brew.sh and re-run."
    exit 1
  fi
}

brew_install() {
  local pkg="$1"
  if brew list "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    info "Installing $pkg..."
    brew install "$pkg"
  fi
}

brew_cask_install() {
  local pkg="$1"
  if brew list --cask "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    info "Installing $pkg (cask)..."
    brew install --cask "$pkg"
  fi
}

# ── Homebrew ───────────────────────────────────────────────────────────────────
require_brew

# ── Common tools ───────────────────────────────────────────────────────────────
brew_install python3
brew_install ansible
brew_install kubectl

# ── Docker Desktop ─────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker Desktop..."
  brew_cask_install docker
  echo ""
  warn "Docker Desktop installed. Open it from Applications and start it."
  warn "Re-run this script after Docker is running."
else
  ok "Docker already available"
fi

# ── Vagrant ────────────────────────────────────────────────────────────────────
brew_cask_install vagrant

# ── Platform-specific VM backend ───────────────────────────────────────────────
if [[ "$ARCH" == "arm64" ]]; then
  echo ""
  echo "=== Apple Silicon detected ==="
  echo ""
  echo "You need ONE of the following VM backends:"
  echo ""
  echo "  Option A (recommended): vagrant-qemu + socket_vmnet"
  echo "  Option B (alternative):  Lima"
  echo ""
  read -rp "Which option? [A/b] " choice
  choice="${choice:-A}"
  choice="$(echo "$choice" | tr '[:lower:]' '[:upper:]')"

  if [[ "$choice" == "A" ]]; then
    # ── Option A: vagrant-qemu + socket_vmnet ──────────────────────────────────
    brew_install qemu

    info "Installing vagrant-qemu plugin..."
    if vagrant plugin list 2>/dev/null | grep -q vagrant-qemu; then
      ok "vagrant-qemu already installed"
    else
      vagrant plugin install vagrant-qemu
    fi

    # socket_vmnet — required for host-only networking in QEMU VMs
    echo ""
    info "Setting up socket_vmnet for QEMU host-only networking..."
    if brew list socket_vmnet >/dev/null 2>&1; then
      ok "socket_vmnet already installed"
    else
      brew install socket_vmnet
    fi

    # Integrate with launchd (requires sudo once)
    if ! launchctl print system/io.github.virtualsquare.vde.socket_vmnet >/dev/null 2>&1; then
      info "Registering socket_vmnet with launchd (requires sudo)..."
      sudo brew services start socket_vmnet
      ok "socket_vmnet service started"
    else
      ok "socket_vmnet service already registered"
    fi

    echo ""
    ok "Option A setup complete. Use: vagrant up --provider qemu"
    echo "Or just: make up  (the Makefile picks the right provider automatically)"

  else
    # ── Option B: Lima ─────────────────────────────────────────────────────────
    brew_install lima

    # Lima also needs socket_vmnet for vmnet-shared (inter-VM networking)
    echo ""
    info "Installing socket_vmnet for Lima vmnet-shared networking..."
    if brew list socket_vmnet >/dev/null 2>&1; then
      ok "socket_vmnet already installed"
    else
      brew install socket_vmnet
    fi

    if ! launchctl print system/io.github.virtualsquare.vde.socket_vmnet >/dev/null 2>&1; then
      info "Registering socket_vmnet with launchd (requires sudo)..."
      sudo brew services start socket_vmnet
    else
      ok "socket_vmnet service already registered"
    fi

    # Authorize socket_vmnet for Lima
    if ! limactl sudoers 2>/dev/null | sudo tee /etc/sudoers.d/lima >/dev/null; then
      warn "Failed to write Lima sudoers — Lima vmnet may not work."
      warn "Try manually: limactl sudoers | sudo tee /etc/sudoers.d/lima"
    else
      ok "Lima sudoers configured"
    fi

    echo ""
    ok "Option B setup complete. Use: bash scripts/lima-up.sh"
    echo "Then run Ansible with: bash scripts/ansible-lima.sh ansible/site.yml"
  fi

else
  # ── Intel Mac: VirtualBox ───────────────────────────────────────────────────
  echo ""
  echo "=== Intel Mac detected — installing VirtualBox ==="
  brew_cask_install virtualbox

  info "Installing vagrant-vbguest plugin..."
  if vagrant plugin list 2>/dev/null | grep -q vagrant-vbguest; then
    ok "vagrant-vbguest already installed"
  else
    vagrant plugin install vagrant-vbguest
  fi

  echo ""
  ok "Intel Mac setup complete. Use: vagrant up"
fi

# ── Ansible collections ────────────────────────────────────────────────────────
echo ""
info "Installing Ansible collections..."
(cd "$(dirname "$0")/.." && ansible-galaxy collection install -r ansible/requirements.yml --force)
ok "Ansible collections installed"

# ── Final check ───────────────────────────────────────────────────────────────
echo ""
echo "=== Final check ==="
make -C "$(dirname "$0")/.." check
