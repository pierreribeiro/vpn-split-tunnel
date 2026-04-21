#!/bin/bash
# =============================================================================
# watchdog.sh - Monitora e reinicia servicos dentro do container
# =============================================================================
# Executado como background process pelo vpn_connect.sh
# Verifica: tun0, microsocks, tinyproxy, socat (port forwards + DNS)
# Se um servico cair, reinicia automaticamente e loga o evento
# =============================================================================

LOGFILE="/var/log/vpn/watchdog.log"
CHECK_INTERVAL=${WATCHDOG_INTERVAL:-30}
MAX_VPN_RETRIES=3
VPN_RETRY_COUNT=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

restart_microsocks() {
    log "ALERT: microsocks caiu. Reiniciando..."
    microsocks -i 0.0.0.0 -p 8889 &
    sleep 1
    if netstat -tlnp 2>/dev/null | grep -q ":8889"; then
        log "OK: microsocks reiniciado com sucesso"
    else
        log "FAIL: microsocks nao reiniciou"
    fi
}

restart_tinyproxy() {
    log "ALERT: tinyproxy caiu. Reiniciando..."
    tinyproxy -c /etc/tinyproxy/tinyproxy.conf &
    sleep 1
    if netstat -tlnp 2>/dev/null | grep -q ":8888"; then
        log "OK: tinyproxy reiniciado com sucesso"
    else
        log "FAIL: tinyproxy nao reiniciou"
    fi
}

restart_socat() {
    local listen_port=$1
    local target=$2
    local proto=${3:-TCP4}
    log "ALERT: socat :$listen_port caiu. Reiniciando..."
    if [ "$proto" = "UDP4" ]; then
        socat UDP4-RECVFROM:$listen_port,fork,reuseaddr UDP4:$target &
    else
        socat TCP4-LISTEN:$listen_port,fork,reuseaddr TCP4:$target &
    fi
    sleep 1
    log "OK: socat :$listen_port reiniciado"
}

check_tun0() {
    if ip link show tun0 2>/dev/null | grep -q "UP"; then
        VPN_RETRY_COUNT=0
        return 0
    else
        VPN_RETRY_COUNT=$((VPN_RETRY_COUNT + 1))
        log "CRITICAL: tun0 DOWN (tentativa $VPN_RETRY_COUNT/$MAX_VPN_RETRIES)"
        if [ $VPN_RETRY_COUNT -ge $MAX_VPN_RETRIES ]; then
            log "CRITICAL: tun0 DOWN apos $MAX_VPN_RETRIES tentativas. OpenConnect pode ter caido."
            log "CRITICAL: Verificar: openconnect --reconnect-timeout pode estar expirado"
        fi
        return 1
    fi
}

check_process() {
    local name=$1
    pgrep -f "$name" > /dev/null 2>&1
    return $?
}

check_port() {
    local port=$1
    netstat -tlnp 2>/dev/null | grep -q ":$port " || \
    netstat -ulnp 2>/dev/null | grep -q ":$port "
    return $?
}

# =============================================================================
# Main loop
# =============================================================================
log "Watchdog iniciado (intervalo: ${CHECK_INTERVAL}s)"

while true; do
    sleep "$CHECK_INTERVAL"

    # 1. Verificar tun0 (VPN tunnel)
    check_tun0

    # 2. Verificar microsocks (SOCKS5 :8889)
    if ! check_process "microsocks"; then
        restart_microsocks
    fi

    # 3. Verificar tinyproxy (HTTP :8888)
    if ! check_process "tinyproxy"; then
        restart_tinyproxy
    fi

    # 4. Verificar socat port forwards
    if ! check_port 11433; then
        restart_socat 11433 "10.10.22.136:1433"
    fi
    if ! check_port 15432; then
        restart_socat 15432 "10.10.22.215:5432"
    fi

    # 5. Verificar DNS forwarder
    if ! check_port 53; then
        restart_socat 53 "192.168.0.7:53" "UDP4"
        restart_socat 53 "192.168.0.7:53" "TCP4"
    fi
done