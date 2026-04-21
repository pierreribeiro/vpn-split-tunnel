#Requires -RunAsAdministrator
# =============================================================================
# vpn-down.ps1 - Desliga infraestrutura Split Tunneling VPN
# =============================================================================
# Uso: .\vpn-down.ps1            (stop container)
#      .\vpn-down.ps1 -Destroy   (docker compose down - remove container+rede)
#      .\vpn-down.ps1 -SkipDNS   (nao remove regras NRPT)
# =============================================================================
param(
    [switch]$Destroy,
    [switch]$SkipDNS
)

$ErrorActionPreference = "Continue"

# --- Carregar configuracao ---
$configPath = Join-Path $PSScriptRoot "vpn-config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "Arquivo vpn-config.ps1 nao encontrado em $PSScriptRoot"
    exit 1
}
. $configPath

# --- Funcoes auxiliares ---
function Write-Step  { param([string]$msg) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] OK: $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] WARN: $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host " VPN Split Tunnel -- Shutting Down"        -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Yellow

# =============================================================================
# 1. REMOVER DNS SPLIT (NRPT)
# =============================================================================
if (-not $SkipDNS) {
    Write-Step "Removendo regras NRPT..."
    foreach ($rule in $VPN_NRPT_RULES) {
        Get-DnsClientNrptRule |
            Where-Object { $_.DisplayName -eq $rule.DisplayName } |
            Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue
        Write-Ok "Removido: $($rule.DisplayName)"
    }
    Clear-DnsClientCache
    Write-Ok "DNS cache limpo"
}

# =============================================================================
# 2. PARAR CONTAINER
# =============================================================================
Write-Step "Parando container VPN..."

Push-Location $VPN_PROJECT_DIR
try {
    if ($Destroy) {
        Invoke-Expression "$VPN_COMPOSE_CMD down"
        Write-Ok "Container + rede removidos (compose down)"
    }
    else {
        Invoke-Expression "$VPN_COMPOSE_CMD stop vpn"
        Write-Ok "Container parado (compose stop)"
    }
}
finally {
    Pop-Location
}

# =============================================================================
# 3. RESUMO
# =============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host " VPN Split Tunnel -- DESLIGADO"            -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host ""
$modeStr = if ($Destroy) { "removido" } else { "parado (docker compose start para retomar)" }
Write-Host " Container: $modeStr" -ForegroundColor Cyan
$dnsStr = if ($SkipDNS) { "mantido" } else { "limpo" }
Write-Host " NRPT:      $dnsStr" -ForegroundColor Cyan
Write-Host " Internet:  direto via default gateway (sem alteracao)" -ForegroundColor Cyan
Write-Host ""
