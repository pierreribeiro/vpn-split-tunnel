#!/bin/bash

# 1. Carregar Docker Secrets e variáveis de ambiente
VPN_PASSWORD=$(cat /run/secrets/vpn_password)

# 2. Iniciar rsyslog (chamada direta ao binário)
touch /var/log/syslog
/usr/sbin/rsyslogd

# 3. Garantir dispositivo TUN
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
fi
chmod 666 /dev/net/tun

# 4. Habilitar o encaminhamento no kernel do contêiner
sysctl -w net.ipv4.ip_forward=1

# Regras de Forwarding para permitir tráfego bidirecional
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Source NAT (Masquerade) para o tráfego sair pela VPN
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# MSS Clamping (Essencial para GitLab/Jira via VPN para evitar pacotes truncados)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Kill switch - bloqueia trafego se tun0 cair
# Permite: Docker internal, DNS, VPN gateway (para reconexao), proxies locais
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A OUTPUT -d 172.28.0.0/16 -j ACCEPT
iptables -A OUTPUT -d 189.57.198.2/32 -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -d 189.57.198.2/32 -p udp --dport 443 -j ACCEPT
iptables -A OUTPUT -o eth0 -j DROP

echo "Kill switch iptables ativo"

echo "========================================="
echo "Iniciando OpenConnect - Amyris Campinas"
echo "========================================="

# 5. Conexão automática da VPN
echo "$VPN_PASSWORD" | openconnect $VPN_GATEWAY \
    --user="$VPN_USERNAME" \
    --passwd-on-stdin \
    --servercert pin-sha256:$VPN_FINGERPRINT \
	--force-dpd=30 \
	--reconnect-timeout=300 \
    --background \
    --interface=tun0 \
    --script=/usr/share/vpnc-scripts/vpnc-script

# Aguarda a interface subir
sleep 5

# 6. Configuração de Rotas (Tratamento de strings)
if [ ! -z "$VPN_ROUTES" ]; then
    echo "Configurando tabelas de roteamento corporativo..."
    # Converte a string separada por espaços em array e itera
    for route in $VPN_ROUTES; do
        echo "Adicionando rota: $route"
        ip route add $route dev tun0 || echo "Aviso: Rota $route já existe ou falhou."
    done
fi

# 7. Log de sucesso
if ip addr show tun0 > /dev/null 2>&1; then
    echo "VPN Conectada com sucesso em $(date)" >> /var/log/vpn/connection.log
    echo "Túnel estabelecido."
else
    echo "ERRO: Falha ao estabelecer túnel VPN." >> /var/log/vpn/connection.log
    exit 1
fi

# 8. Iniciar proxies
echo "Iniciando proxies..."
microsocks -i 0.0.0.0 -p 8889 &
tinyproxy -c /etc/tinyproxy/tinyproxy.conf &
echo "Proxies ativos: HTTP :8888, SOCKS5 :8889"

# 9. Port forwarding para apps proxy-blind (Modo B)
echo "Iniciando port forwarding corporativo..."
# Ajuste os IPs/hostnames para os servidores reais
socat TCP-LISTEN:11433,fork,reuseaddr TCP:10.10.22.136:1433 &
socat TCP-LISTEN:15432,fork,reuseaddr TCP:10.10.22.215:5432 &
echo "Port forwards ativos: SQL :11433, PG :15432"

# 10. DNS forwarder para NRPT
socat UDP4-RECVFROM:53,fork,reuseaddr UDP4:192.168.0.7:53
socat TCP4-LISTEN:53,fork,reuseaddr TCP4:192.168.0.7:53
echo "DNS forwarder ativo: :53 → 192.168.0.7:53"

# 11. Watchdog (auto-restart de servicos)
/scripts/watchdog.sh &
echo "Watchdog ativo (intervalo: 30s)"

# 12. Mantém o container vivo e monitora o syslog
tail -f /var/log/syslog