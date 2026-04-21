#Requires -RunAsAdministrator
# =============================================================================
# vpn-up.ps1 - Inicia infraestrutura Split Tunneling VPN
# =============================================================================
# Uso: .\vpn-up.ps1              (start normal)
#      .\vpn-up.ps1 -SkipDNS     (sem configurar NRPT)
# =============================================================================
param(
    [switch]$SkipDNS
)

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
function Write-Fail  { param([string]$msg) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] FAIL: $msg" -ForegroundColor Red }

# =============================================================================
# 1. PRE-REQUISITOS
# =============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " VPN Split Tunnel -- Starting Up"          -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

Write-Step "Verificando pre-requisitos..."

# Docker Desktop rodando?
$dockerStatus = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker Desktop nao esta rodando. Inicie-o primeiro."
    exit 1
}
Write-Ok "Docker Desktop ativo"

# WSL2 ativo?
$wslOutput = (wsl hostname -I 2>$null) -join ' '
if ([string]::IsNullOrWhiteSpace($wslOutput)) {
    Write-Fail "WSL2 nao esta rodando ou IP nao foi retornado."
    exit 1
}
$wslIp = $wslOutput.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)[0]
Write-Ok "WSL2 ativo [IP: $wslIp]"

# =============================================================================
# 2. INICIAR CONTAINER
# =============================================================================
Write-Step "Iniciando container VPN..."

Push-Location $VPN_PROJECT_DIR
try {
    $containerState = docker inspect -f '{{.State.Status}}' $VPN_CONTAINER_NAME 2>$null
    if ($containerState -eq "running") {
        Write-Warn "Container ja esta rodando"
    }
    elseif ($containerState -eq "exited") {
        Invoke-Expression "$VPN_COMPOSE_CMD start vpn"
    }
    else {
        Invoke-Expression "$VPN_COMPOSE_CMD up -d"
    }
}
finally {
    Pop-Location
}

# =============================================================================
# 3. AGUARDAR HEALTH CHECK
# =============================================================================
Write-Step "Aguardando tunel VPN estabilizar ($VPN_STARTUP_WAIT s)..."
Start-Sleep -Seconds $VPN_STARTUP_WAIT

$healthy = $false
for ($i = 1; $i -le $VPN_HEALTH_RETRIES; $i++) {
    $health = docker inspect --format='{{.State.Health.Status}}' $VPN_CONTAINER_NAME 2>$null
    if ($health -eq "healthy") {
        $healthy = $true
        break
    }
    Write-Warn "Health check tentativa $i/$VPN_HEALTH_RETRIES [status: $health]..."
    Start-Sleep -Seconds 5
}

if (-not $healthy) {
    Write-Fail "Container nao ficou healthy. Verifique: docker logs $VPN_CONTAINER_NAME"
    exit 1
}
Write-Ok "Container healthy -- tunel tun0 ativo"

# Aguardar proxies e socat subirem apos health check
Write-Step "Aguardando servicos internos (5s)..."
Start-Sleep -Seconds 5

# =============================================================================
# 4. VALIDAR PROXIES E PORT FORWARDS
# =============================================================================
Write-Step "Validando servicos internos..."

# Modo A -- Proxies
$socks = Test-NetConnection -ComputerName 127.0.0.1 -Port $VPN_SOCKS5_PORT -WarningAction SilentlyContinue
$http  = Test-NetConnection -ComputerName 127.0.0.1 -Port $VPN_HTTP_PORT -WarningAction SilentlyContinue

if ($socks.TcpTestSucceeded) { Write-Ok "SOCKS5 proxy :$VPN_SOCKS5_PORT" }
else { Write-Warn "SOCKS5 proxy :$VPN_SOCKS5_PORT nao respondeu" }

if ($http.TcpTestSucceeded) { Write-Ok "HTTP proxy :$VPN_HTTP_PORT" }
else { Write-Warn "HTTP proxy :$VPN_HTTP_PORT nao respondeu" }

# Modo B -- Port Forwards
foreach ($fwd in $VPN_FORWARDS) {
    $test = Test-NetConnection -ComputerName 127.0.0.1 -Port $fwd.LocalPort -WarningAction SilentlyContinue
    if ($test.TcpTestSucceeded) { Write-Ok "$($fwd.Desc) :$($fwd.LocalPort)" }
    else { Write-Warn "$($fwd.Desc) :$($fwd.LocalPort) nao respondeu" }
}

# =============================================================================
# 5. CONFIGURAR DNS SPLIT (NRPT)
# =============================================================================
if (-not $SkipDNS) {
    Write-Step "Configurando DNS split (NRPT)..."

    foreach ($rule in $VPN_NRPT_RULES) {
        Get-DnsClientNrptRule |
            Where-Object { $_.DisplayName -eq $rule.DisplayName } |
            Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue

        Add-DnsClientNrptRule `
            -Namespace $rule.Namespace `
            -NameServers $VPN_DNS_BIND_IP `
            -DisplayName $rule.DisplayName

        Write-Ok "NRPT: $($rule.Namespace) -> $VPN_DNS_BIND_IP"
    }

    Clear-DnsClientCache
    Write-Ok "DNS cache limpo"
}
else {
    Write-Warn "DNS split ignorado (-SkipDNS)"
}

# =============================================================================
# 6. RESUMO FINAL
# =============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " VPN Split Tunnel -- ATIVO"                -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Modo A (Proxy):" -ForegroundColor Cyan
Write-Host "   SOCKS5  -> 127.0.0.1:$VPN_SOCKS5_PORT"
Write-Host "   HTTP    -> 127.0.0.1:$VPN_HTTP_PORT"
Write-Host ""
Write-Host " Modo B (Port Forward):" -ForegroundColor Cyan
foreach ($fwd in $VPN_FORWARDS) {
    Write-Host "   $($fwd.Desc) -> 127.0.0.1:$($fwd.LocalPort)"
}
Write-Host ""
Write-Host " Modo C (Direct):" -ForegroundColor Cyan
Write-Host "   Internet -> default gateway (home router)"
Write-Host ""
if (-not $SkipDNS) {
    Write-Host " DNS Split (NRPT):" -ForegroundColor Cyan
    foreach ($rule in $VPN_NRPT_RULES) {
        Write-Host "   $($rule.Namespace) -> $VPN_DNS_BIND_IP"
    }
}
Write-Host ""
Write-Host " Uso rapido:" -ForegroundColor Yellow
Write-Host '   curl.exe -x socks5h://127.0.0.1:8889 -k https://git.amyris.local'
Write-Host '   SSMS -> Server: 127.0.0.1,11433'
Write-Host '   psql -h 127.0.0.1 -p 15432 -U pierre'
Write-Host ""
