# setup-windows.ps1
# Install Windows-side prerequisites for The Store K3s lab.
# Run as Administrator in PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1
#
# After this script completes:
#   1. Open WSL2 (Ubuntu) and run: bash scripts/setup-linux.sh
#   2. Start VMs: vagrant up  (from Windows Terminal, NOT from WSL)
#   3. Run Ansible: bash scripts/ansible-wsl.sh  (from WSL2)

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

function Write-OK   { Write-Host "[OK]  $args" -ForegroundColor Green }
function Write-Info { Write-Host "[..]  $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "[!!]  $args" -ForegroundColor Yellow }

# ── Winget check ──────────────────────────────────────────────────────────────
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warn "winget not found. Install App Installer from the Microsoft Store."
    exit 1
}

# ── Helper: install via winget if not present ─────────────────────────────────
function Install-Via-Winget {
    param($Id, $Name)
    $installed = winget list --id $Id --exact 2>$null | Select-String $Id
    if ($installed) {
        Write-OK "$Name already installed"
    } else {
        Write-Info "Installing $Name..."
        winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
        Write-OK "$Name installed"
    }
}

# ── WSL2 ──────────────────────────────────────────────────────────────────────
Write-Info "Enabling WSL2..."
$wslFeature = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State
if ($wslFeature -eq "Enabled") {
    Write-OK "WSL already enabled"
} else {
    wsl --install
    Write-Warn "WSL2 enabled. A restart may be required before continuing."
}

# ── VirtualBox ────────────────────────────────────────────────────────────────
Install-Via-Winget "Oracle.VirtualBox" "VirtualBox"

# ── Vagrant ───────────────────────────────────────────────────────────────────
Install-Via-Winget "Hashicorp.Vagrant" "Vagrant"

# ── Docker Desktop ────────────────────────────────────────────────────────────
Install-Via-Winget "Docker.DockerDesktop" "Docker Desktop"
Write-Warn "After Docker Desktop starts, go to:"
Write-Warn "  Settings → Resources → WSL Integration → Enable for your Ubuntu distro"

# ── Git (for WSL-less git operations) ────────────────────────────────────────
Install-Via-Winget "Git.Git" "Git"

# ── kubectl (optional, for Windows kubectl access) ───────────────────────────
$kube = Get-Command kubectl -ErrorAction SilentlyContinue
if ($kube) {
    Write-OK "kubectl already installed"
} else {
    Write-Info "Installing kubectl..."
    winget install --id Kubernetes.kubectl --exact --silent --accept-package-agreements --accept-source-agreements
    Write-OK "kubectl installed"
}

# ── Reload PATH ───────────────────────────────────────────────────────────────
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Windows setup complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Restart your machine if prompted by WSL"
Write-Host "  2. Open Docker Desktop and enable WSL2 integration for your Ubuntu distro"
Write-Host "  3. Open WSL2 Ubuntu and run: bash scripts/setup-linux.sh"
Write-Host "  4. Bring up VMs from Windows Terminal (NOT from WSL):"
Write-Host "       vagrant up"
Write-Host "  5. Run Ansible from WSL2:"
Write-Host "       bash scripts/ansible-wsl.sh ansible/site.yml"
Write-Host ""
Write-Host "The Vagrant insecure key is at:"
Write-Host "  C:\Users\$env:USERNAME\.vagrant.d\insecure_private_key"
Write-Host "The WSL script (ansible-wsl.sh) copies it to WSL automatically."
