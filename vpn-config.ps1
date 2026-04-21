# =============================================================================
# vpn-config.ps1 - Variaveis de ambiente para Split Tunneling
# =============================================================================
# INSTRUCOES: Ajuste este arquivo para cada maquina/notebook.
# Os scripts vpn-up/down/status importam este arquivo automaticamente.
# =============================================================================

# --- Docker Compose ---
$VPN_PROJECT_DIR    = "C:\Temp\openconnect"
$VPN_CONTAINER_NAME = "openconnect-vpn"
$VPN_COMPOSE_CMD    = "docker compose"

# --- Proxies (Modo A) ---
$VPN_SOCKS5_PORT = 8889
$VPN_HTTP_PORT   = 8888

# --- Port Forwards (Modo B - socat) ---
$VPN_FORWARDS = @(
    @{ LocalPort = 11433; Desc = "SQL Server Amyris" },
    @{ LocalPort = 15432; Desc = "PostgreSQL Amyris" }
)

# --- DNS Split (NRPT) ---
$VPN_DNS_BIND_IP   = "10.0.0.33"
$VPN_DNS_PORT      = 53
$VPN_NRPT_RULES    = @(
    @{ Namespace = ".amyris.local";  DisplayName = "Amyris-Corp-DNS" },
    @{ Namespace = ".amyris.com";    DisplayName = "Amyris-Ext-DNS" }
)

# --- Timeouts ---
$VPN_STARTUP_WAIT  = 15
$VPN_HEALTH_RETRIES = 6
