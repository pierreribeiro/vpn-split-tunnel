# =============================================================================
# vpn-monitor.ps1 - Monitoramento continuo com alertas Windows
# =============================================================================
# Uso: .\vpn-monitor.ps1                   (check unico - para Task Scheduler)
#      .\vpn-monitor.ps1 -Continuous        (loop a cada 60s)
#      .\vpn-monitor.ps1 -Continuous -Interval 30
# =============================================================================
param(
    [switch]$Continuous,
    [int]$Interval = 60
)

# --- Carregar configuracao ---
$configPath = Join-Path $PSScriptRoot "vpn-config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "Arquivo vpn-config.ps1 nao encontrado em $PSScriptRoot"
    exit 1
}
. $configPath

# --- Toast notification (Windows 10/11 nativo) ---
function Send-Toast {
    param([string]$Title, [string]$Message, [string]$Level = "Info")

    $icon = switch ($Level) {
        "Error"   { "error" }
        "Warning" { "warning" }
        default   { "info" }
    }

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$Title</text>
            <text>$Message</text>
        </binding>
    </visual>
    <audio silent="false"/>
</toast>
"@
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("VPN Split Tunnel")
        $notifier.Show($toast)
    }
    catch {
        # Fallback: BurntToast ou console warning
        Write-Host "[$Level] $Title - $Message" -ForegroundColor $(
            switch ($Level) { "Error" {"Red"} "Warning" {"Yellow"} default {"Cyan"} }
        )
    }
}

# --- Log ---
$logDir = Join-Path $VPN_PROJECT_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "vpn-monitor.log"

function Write-Log {
    param([string]$msg, [string]$level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $msg"
    Add-Content -Path $logFile -Value $line
    if ($level -eq "ERROR" -or $level -eq "CRITICAL") {
        Write-Host $line -ForegroundColor Red
    }
}

# --- Checks ---
function Invoke-HealthCheck {
    $failures = @()
    $warnings = @()

    # 1. Container running?
    $state = docker inspect -f '{{.State.Status}}' $VPN_CONTAINER_NAME 2>$null
    if ($state -ne "running") {
        $failures += "Container nao esta rodando (status: $state)"
    }

    # 2. Container healthy?
    if ($state -eq "running") {
        $health = docker inspect -f '{{.State.Health.Status}}' $VPN_CONTAINER_NAME 2>$null
        if ($health -ne "healthy") {
            $failures += "Container unhealthy (tun0 DOWN?)"
        }
    }

    # 3. SOCKS5 proxy
    $s = Test-NetConnection 127.0.0.1 -Port $VPN_SOCKS5_PORT -WarningAction SilentlyContinue
    if (-not $s.TcpTestSucceeded) {
        $warnings += "SOCKS5 :$VPN_SOCKS5_PORT nao responde"
    }

    # 4. HTTP proxy
    $h = Test-NetConnection 127.0.0.1 -Port $VPN_HTTP_PORT -WarningAction SilentlyContinue
    if (-not $h.TcpTestSucceeded) {
        $warnings += "HTTP :$VPN_HTTP_PORT nao responde"
    }

    # 5. Port forwards
    foreach ($fwd in $VPN_FORWARDS) {
        $t = Test-NetConnection 127.0.0.1 -Port $fwd.LocalPort -WarningAction SilentlyContinue
        if (-not $t.TcpTestSucceeded) {
            $warnings += "$($fwd.Desc) :$($fwd.LocalPort) nao responde"
        }
    }

    # 6. NRPT rules
    $nrpt = Get-DnsClientNrptRule 2>$null | Where-Object { $_.DisplayName -like "Amyris*" }
    if ($nrpt.Count -eq 0) {
        $warnings += "NRPT rules nao configuradas"
    }

    # 7. DNS functional test
    if ($nrpt.Count -gt 0) {
        try {
            $dns = Resolve-DnsName git.amyris.local -ErrorAction Stop -DnsOnly 2>$null
            if (-not $dns) { $warnings += "DNS resolve falhou para git.amyris.local" }
        }
        catch {
            $warnings += "DNS resolve timeout para git.amyris.local"
        }
    }

    # --- Process results ---
    $timestamp = Get-Date -Format "HH:mm:ss"

    if ($failures.Count -gt 0) {
        $msg = $failures -join "; "
        Write-Log $msg "CRITICAL"
        Send-Toast "VPN CRITICO" $msg "Error"
        Write-Host "[$timestamp] CRITICAL: $msg" -ForegroundColor Red
        return $false
    }
    elseif ($warnings.Count -gt 0) {
        $msg = $warnings -join "; "
        Write-Log $msg "WARNING"
        Send-Toast "VPN Alerta" $msg "Warning"
        Write-Host "[$timestamp] WARNING: $msg" -ForegroundColor Yellow
        return $true
    }
    else {
        Write-Log "Todos os servicos OK" "INFO"
        Write-Host "[$timestamp] OK: Todos os servicos operacionais" -ForegroundColor Green
        return $true
    }
}

# =============================================================================
# Execucao
# =============================================================================
if ($Continuous) {
    Write-Host "=== VPN Monitor (a cada ${Interval}s) ===" -ForegroundColor Cyan
    Write-Host "Ctrl+C para parar" -ForegroundColor Yellow
    Write-Host ""
    while ($true) {
        Invoke-HealthCheck | Out-Null
        Start-Sleep -Seconds $Interval
    }
}
else {
    Invoke-HealthCheck | Out-Null
}