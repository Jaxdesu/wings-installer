#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/wings-installer.log"
WINGS_DIR="/etc/pterodactyl"
WINGS_BIN="/usr/local/bin/wings"
WINGS_SERVICE="/etc/systemd/system/wings.service"
WINGS_WAS_ACTIVE=false
STOPPED_WEBSERVERS=()

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BLUE=''
    RESET=''
fi

log()  { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[AVISO]%b %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%b[ERRO]%b %s\n' "$RED" "$RESET" "$*" >&2; }

on_error() {
    local exit_code=$?
    local line_no=${1:-?}
    err "Falha na linha ${line_no} (código ${exit_code}). Consulte ${LOG_FILE}."
    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "Execute este instalador como root (ex.: sudo -i)."
        exit 1
    fi
}

setup_logging() {
    install -d -m 0755 "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

ask_yes_no() {
    local question=$1
    local default=${2:-n}
    local answer

    while true; do
        if [[ "$default" == "s" ]]; then
            read -r -p "$question [S/n]: " answer || true
            answer=${answer:-s}
        else
            read -r -p "$question [s/N]: " answer || true
            answer=${answer:-n}
        fi

        case "${answer,,}" in
            s|sim|y|yes) return 0 ;;
            n|nao|não|no) return 1 ;;
            *) printf 'Responda com s ou n.\n' ;;
        esac
    done
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        err "Este instalador requer uma distribuição Linux usando systemd."
        exit 1
    fi
}

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        err "Não foi possível detectar o sistema operacional."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    log "Sistema detectado: ${PRETTY_NAME:-${ID:-Linux}}"

    case "${ID:-}" in
        ubuntu|debian|rhel|rocky|almalinux|centos|fedora) ;;
        *) warn "Distribuição '${ID:-desconhecida}' não está na lista principal de suporte deste instalador." ;;
    esac
}

check_virtualization() {
    local virt='unknown'
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || true)
        virt=${virt:-none}
    fi

    case "$virt" in
        lxc|openvz|vz)
            warn "Virtualização detectada: $virt. Docker/Wings pode exigir suporte a nesting do provedor."
            ;;
        *)
            log "Virtualização detectada: $virt"
            ;;
    esac
}

install_base_packages() {
    log "Instalando dependências básicas..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends curl ca-certificates gnupg openssl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates gnupg2 openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates gnupg2 openssl
    else
        err "Gerenciador de pacotes não suportado automaticamente."
        exit 1
    fi
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker já está instalado: $(docker --version 2>/dev/null || echo 'versão não detectada')"
    else
        log "Docker não encontrado. Instalando Docker CE..."
        local docker_script
        docker_script=$(mktemp)
        curl -fsSL --retry 3 --connect-timeout 15 https://get.docker.com -o "$docker_script"
        CHANNEL=stable sh "$docker_script"
        rm -f "$docker_script"
    fi

    systemctl enable --now docker

    if ! systemctl is-active --quiet docker; then
        err "Docker foi instalado, mas o serviço não está ativo."
        systemctl status docker --no-pager || true
        exit 1
    fi

    log "Docker habilitado para iniciar automaticamente no boot."
}

detect_wings_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

install_wings_binary() {
    local wings_arch
    local download_url
    local tmp_bin

    if ! wings_arch=$(detect_wings_arch); then
        err "Arquitetura não suportada automaticamente: $(uname -m)"
        exit 1
    fi

    install -d -m 0755 "$WINGS_DIR"

    download_url="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${wings_arch}"
    tmp_bin=$(mktemp)

    log "Baixando a versão estável mais recente do Wings (${wings_arch})..."
    if ! curl -fL --retry 3 --connect-timeout 15 "$download_url" -o "$tmp_bin"; then
        rm -f "$tmp_bin"
        err "Falha ao baixar o Wings. O binário atual não foi alterado."
        exit 1
    fi
    chmod 0755 "$tmp_bin"

    if systemctl is-active --quiet wings 2>/dev/null; then
        WINGS_WAS_ACTIVE=true
        log "Wings está ativo. Parando o serviço por alguns segundos para atualizar o binário..."
        systemctl stop wings
    fi

    if [[ -x "$WINGS_BIN" ]]; then
        local backup="${WINGS_BIN}.backup.$(date +%Y%m%d-%H%M%S)"
        cp -a "$WINGS_BIN" "$backup"
        log "Backup do binário atual criado em $backup"
    fi

    if ! install -o root -g root -m 0755 "$tmp_bin" "${WINGS_BIN}.new"; then
        rm -f "$tmp_bin" "${WINGS_BIN}.new"
        if [[ "$WINGS_WAS_ACTIVE" == true ]]; then
            systemctl start wings || true
        fi
        err "Falha ao preparar o novo binário do Wings; a versão atual foi preservada."
        exit 1
    fi

    mv -f "${WINGS_BIN}.new" "$WINGS_BIN"
    rm -f "$tmp_bin"

    log "Wings instalado em $WINGS_BIN"
    "$WINGS_BIN" --version 2>/dev/null || true
}

create_wings_service() {
    log "Configurando serviço systemd do Wings..."

    cat > "$WINGS_SERVICE" <<'EOF_SERVICE'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod 0644 "$WINGS_SERVICE"
    systemctl daemon-reload

    # Habilita independentemente de config.yml existir. Assim o Wings fica
    # registrado para iniciar no boot assim que a configuração estiver presente.
    systemctl enable wings

    if ! systemctl is-enabled --quiet wings; then
        err "Não foi possível habilitar o Wings para iniciar no boot."
        exit 1
    fi

    log "Wings habilitado para iniciar automaticamente após reinicializações."
}

check_wings_config() {
    if [[ -s "$WINGS_DIR/config.yml" ]]; then
        chmod 0600 "$WINGS_DIR/config.yml"
        log "Config encontrada em $WINGS_DIR/config.yml"
        return 0
    fi

    warn "Config do Wings ainda não encontrada em $WINGS_DIR/config.yml."
    warn "O serviço já está habilitado no boot, mas não será iniciado agora sem a configuração."
    return 1
}

start_wings() {
    if ! check_wings_config; then
        return 0
    fi

    log "Iniciando Wings..."
    systemctl restart wings
    sleep 2

    if systemctl is-active --quiet wings; then
        log "Wings está ativo e habilitado no boot."
    else
        err "Wings não permaneceu ativo após a inicialização."
        journalctl -u wings -n 50 --no-pager || true
        return 1
    fi
}

install_certbot() {
    if command -v certbot >/dev/null 2>&1; then
        log "Certbot já está instalado."
        return 0
    fi

    log "Instalando Certbot..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y certbot
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release
        yum install -y certbot
    else
        warn "Não foi possível instalar o Certbot automaticamente."
        return 1
    fi
}

stop_webservers() {
    local service
    STOPPED_WEBSERVERS=()

    for service in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            if systemctl stop "$service"; then
                STOPPED_WEBSERVERS+=("$service")
                warn "$service foi parado temporariamente para liberar a porta 80."
            else
                warn "Não foi possível parar $service automaticamente."
            fi
        fi
    done
}

restore_webservers() {
    local service
    for service in "${STOPPED_WEBSERVERS[@]:-}"; do
        [[ -n "$service" ]] || continue
        if systemctl start "$service"; then
            log "$service iniciado novamente."
        else
            warn "Não foi possível reiniciar $service automaticamente."
        fi
    done
    STOPPED_WEBSERVERS=()
}

cleanup() {
    if (( ${#STOPPED_WEBSERVERS[@]} > 0 )); then
        restore_webservers || true
    fi
}

trap cleanup EXIT

issue_ssl() {
    local domain email

    read -r -p "Domínio do node/Wings (ex.: node-01.exemplo.com): " domain
    if [[ ! "$domain" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
        warn "Domínio inválido. Pulando emissão do SSL."
        return 0
    fi

    read -r -p "E-mail para Let's Encrypt: " email
    if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        warn "E-mail inválido. Pulando emissão do SSL."
        return 0
    fi

    warn "O domínio deve apontar para este servidor e a porta 80 deve estar acessível pela internet."

    if ask_yes_no "Parar temporariamente Nginx/Apache/Caddy se estiverem usando a porta 80?" "n"; then
        stop_webservers
    fi

    log "Solicitando certificado para $domain..."
    if certbot certonly --standalone --non-interactive --agree-tos -m "$email" -d "$domain"; then
        log "SSL emitido com sucesso."
        printf 'Certificado: /etc/letsencrypt/live/%s/fullchain.pem\n' "$domain"
        printf 'Chave:       /etc/letsencrypt/live/%s/privkey.pem\n' "$domain"

        install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/restart-wings <<'EOF_HOOK'
#!/bin/sh
systemctl try-restart wings >/dev/null 2>&1 || true
EOF_HOOK
        chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/restart-wings

        if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
            systemctl enable --now certbot.timer || true
        fi

        systemctl try-restart wings >/dev/null 2>&1 || true
    else
        warn "Não foi possível emitir o SSL. O restante da instalação continuará."
    fi

    restore_webservers
}

setup_firewall() {
    local daemon_port sftp_port

    if ! command -v ufw >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y ufw
        else
            warn "UFW não está disponível. Configure o firewall manualmente para as portas do Wings."
            return 0
        fi
    fi

    read -r -p "Porta da API do Wings [8080]: " daemon_port
    daemon_port=${daemon_port:-8080}
    read -r -p "Porta SFTP do Wings [2022]: " sftp_port
    sftp_port=${sftp_port:-2022}

    if [[ ! "$daemon_port" =~ ^[0-9]+$ ]] || (( daemon_port < 1 || daemon_port > 65535 )); then
        warn "Porta da API inválida. Usando 8080."
        daemon_port=8080
    fi
    if [[ ! "$sftp_port" =~ ^[0-9]+$ ]] || (( sftp_port < 1 || sftp_port > 65535 )); then
        warn "Porta SFTP inválida. Usando 2022."
        sftp_port=2022
    fi

    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "${daemon_port}/tcp"
    ufw allow "${sftp_port}/tcp"

    if ufw status | grep -q '^Status: active'; then
        log "UFW já está ativo; regras aplicadas."
    elif ask_yes_no "Ativar o UFW agora?" "n"; then
        ufw --force enable
        log "UFW ativado."
    else
        warn "Regras foram adicionadas, mas o UFW continua desativado."
    fi

    ufw status || true
}

show_summary() {
    printf '\n%bResumo%b\n' "$BLUE" "$RESET"
    printf '%s\n' '--------------------------------------'
    printf 'Docker: %s / %s\n' \
        "$(systemctl is-enabled docker 2>/dev/null || true)" \
        "$(systemctl is-active docker 2>/dev/null || true)"
    printf 'Wings:  %s / %s\n' \
        "$(systemctl is-enabled wings 2>/dev/null || true)" \
        "$(systemctl is-active wings 2>/dev/null || true)"
    printf 'Config: %s\n' "$WINGS_DIR/config.yml"
    printf 'Log:    %s\n' "$LOG_FILE"
    printf '%s\n' '--------------------------------------'
    printf 'Logs do Wings: journalctl -u wings -f\n'
    printf 'Status:         systemctl status wings --no-pager\n'
}

main() {
    check_root
    setup_logging
    clear 2>/dev/null || true

    printf '%b' "$BLUE"
    printf '%s\n' '========================================='
    printf '%s\n' '  Instalador Pterodactyl Wings - Jaxdesu'
    printf '%s\n' '========================================='
    printf '%b\n' "$RESET"

    log "Log da instalação: $LOG_FILE"

    require_systemd
    detect_os
    check_virtualization
    install_base_packages
    install_docker
    install_wings_binary
    create_wings_service

    # Em atualizações, reduz o tempo de indisponibilidade do daemon.
    if [[ "$WINGS_WAS_ACTIVE" == true ]]; then
        start_wings
    fi

    if ask_yes_no "Gerar SSL com Certbot para o node?" "n"; then
        if install_certbot; then
            issue_ssl
        fi
    fi

    if ask_yes_no "Configurar UFW para as portas do Wings?" "n"; then
        setup_firewall
    fi

    if [[ "$WINGS_WAS_ACTIVE" != true ]]; then
        start_wings
    fi

    show_summary
    log "Instalação finalizada."
}

main "$@"
