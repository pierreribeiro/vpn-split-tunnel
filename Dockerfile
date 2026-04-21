FROM ubuntu:24.04

# Impedir prompts interativos
ENV DEBIAN_FRONTEND=noninteractive

# 1) Instalação Enxuta (Removido pacotes UI e dependências do Cisco)
RUN apt-get update && apt-get install -y \
    openconnect \
    vpnc-scripts \
    rsyslog \
    iptables \
    iproute2 \
    net-tools \
    iputils-ping \
    curl \
    socat \
    sudo \
	openssh-client \
    vim \
	libnm0 \
	strace \
	traceroute\
	tinyproxy \
	python3 python3-pip python3-venv \
	dnsutils \
    && rm -rf /var/lib/apt/lists/*

# 2) NOVO: microsocks (SOCKS5 leve)
RUN curl -L https://github.com/rofl0r/microsocks/archive/refs/tags/v1.0.3.tar.gz | tar xz \
    && cd microsocks-1.0.3 && make && make install \
    && cd .. && rm -rf microsocks-1.0.3

# 3) NOVO: vpn-slice para split tunnel client-side
RUN python3 -m venv /opt/vpn-slice-venv \
    && /opt/vpn-slice-venv/bin/pip install 'vpn-slice[dnspython,setproctitle]' \
    && ln -s /opt/vpn-slice-venv/bin/vpn-slice /usr/local/bin/vpn-slice
	
# 3) Estrutura de Diretórios Organizada
# /vpn: para certificados e perfis customizados
# /scripts: scripts de automação
RUN mkdir -p /vpn /scripts /var/log/vpn /dev/net

# 4) Configuração do rsyslog para ambiente Docker
RUN sed -i '/imklog/s/^/#/' /etc/rsyslog.conf

# 5) Tinyproxy config (bind em 0.0.0.0:8888)
RUN sed -i 's/^Listen.*/Listen 0.0.0.0/' /etc/tinyproxy/tinyproxy.conf \
    && sed -i 's/^Allow.*/Allow 172.28.0.0\/16\nAllow 127.0.0.1/' /etc/tinyproxy/tinyproxy.conf

# 6) Adicionar certificado da CA (se necessário para o ambiente)    
# CA corporativo (converte DER -> PEM no build)
COPY certs/amyris-root-ca.der /tmp/amyris-root-ca.der
RUN openssl x509 -inform DER -in /tmp/amyris-root-ca.der \
    -out /usr/local/share/ca-certificates/amyris-root-ca.crt \
    && update-ca-certificates \
    && rm /tmp/amyris-root-ca.der
    
# 7) Preparação do script de entrada
COPY watchdog.sh /scripts/watchdog.sh
RUN chmod +x /scripts/watchdog.sh
COPY vpn_connect.sh /scripts/vpn_connect.sh
RUN chmod +x /scripts/vpn_connect.sh

# REMOVIDO: COPY .env (usar volume em runtime)

EXPOSE 8888 8889

WORKDIR /scripts

# Executa o script de conexão ao iniciar
ENTRYPOINT ["/bin/bash", "/scripts/vpn_connect.sh"]