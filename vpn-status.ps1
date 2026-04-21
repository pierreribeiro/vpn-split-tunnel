# =============================================================================
# vpn-status.ps1 - Diagnostico rapido do Split Tunneling
# =============================================================================
# Uso: .\vpn-status.ps1          (nao requer Admin)
# =============================================================================

# --- Carregar configuracao ---
$configPath = Join-Path $PSScriptRoot "vpn-config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "Arquivo vpn-config.ps1 nao encontrado em $PSScriptRoot"
    exit 1
}
. $configPath

function Write-Check { param([string]$label, [bool]$ok, [string]$detail)
    $icon = if ($ok) { "[OK]" } else { "[--]" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("  {0,-6} {1,-28} {2}" -f $icon, $label, $detail) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== VPN Split Tunnel Status ===" -ForegroundColor Cyan
Write-Host ""

# Container
$state = docker inspect -f '{{.State.Status}}' $VPN_CONTAINER_NAME 2>$null
$health = docker inspect -f '{{.State.Health.Status}}' $VPN_CONTAINER_NAME 2>$null
Write-Check "Container" ($state -eq "running") "$state ($health)"

# tun0
if ($state -eq "running") {
    $tun = docker exec $VPN_CONTAINER_NAME ip link show tun0 2>$null    
    Write-Check "tun0" ([bool]($tun -match "UP")) $(if ($tun -match "UP") {"UP"} else {"DOWN"})
}

# Proxies
$s = Test-NetConnection 127.0.0.1 -Port $VPN_SOCKS5_PORT -WarningAction SilentlyContinue
$h = Test-NetConnection 127.0.0.1 -Port $VPN_HTTP_PORT -WarningAction SilentlyContinue
Write-Check "SOCKS5 :$VPN_SOCKS5_PORT" $s.TcpTestSucceeded ""
Write-Check "HTTP   :$VPN_HTTP_PORT" $h.TcpTestSucceeded ""

# Port forwards
foreach ($fwd in $VPN_FORWARDS) {
    $t = Test-NetConnection 127.0.0.1 -Port $fwd.LocalPort -WarningAction SilentlyContinue
    Write-Check "$($fwd.Desc)" $t.TcpTestSucceeded ":$($fwd.LocalPort)"
}

# DNS
$nrpt = Get-DnsClientNrptRule 2>$null | Where-Object { $_.DisplayName -like "Amyris*" }
Write-Check "NRPT rules" ($nrpt.Count -gt 0) "$($nrpt.Count) regra(s)"

# Quick DNS test
if ($nrpt.Count -gt 0) {
    try {
        $dns = Resolve-DnsName git.amyris.local -ErrorAction Stop 2>$null
        Write-Check "DNS resolve" $true "git.amyris.local -> $($dns.IPAddress)"
    }
    catch {
        Write-Check "DNS resolve" $false "git.amyris.local timeout"
    }
}

Write-Host ""
