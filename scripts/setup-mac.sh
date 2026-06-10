#!/usr/bin/env bash
# Install all prerequisites for macOS Apple Silicon.
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

if [[ "$ARCH" != "arm64" ]]; then
  echo ""
  warn "macOS Intel no está soportado por este proyecto."
  warn "Usá Linux nativo o Windows + WSL2 (scripts/setup-linux.sh)."
  exit 1
fi

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

# ── Lima VM backend ────────────────────────────────────────────────────────────
echo ""
echo "=== Apple Silicon detected — installing Lima backend ==="
brew_install lima

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

if ! limactl sudoers 2>/dev/null | sudo tee /etc/sudoers.d/lima >/dev/null; then
  warn "Failed to write Lima sudoers — Lima vmnet may not work."
  warn "Try manually: limactl sudoers | sudo tee /etc/sudoers.d/lima"
else
  ok "Lima sudoers configured"
fi

echo ""
ok "Lima setup complete. Use: make up"
echo "Then deploy with: make deploy"

# ── Ansible collections ────────────────────────────────────────────────────────
echo ""
info "Installing Ansible collections..."
(cd "$(dirname "$0")/.." && ansible-galaxy collection install -r ansible/requirements.yml --force)
ok "Ansible collections installed"

# ── Final check ───────────────────────────────────────────────────────────────
echo ""
echo "=== Final check ==="
make -C "$(dirname "$0")/.." check
