#!/bin/bash

set -Eeuo pipefail

LOG_FILE="/root/wings-install.log"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "[ERRO] Linha $LINENO: comando falhou. Veja o log em $LOG_FILE"' ERR

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

log() {
    echo -e "${GREEN}[OK]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[AVISO]${RESET} $1"
}

err() {
    echo -e "${RED}[ERRO]${RESET} $1"
}

ask_yes_no() {
    local question="$1"
    local default="$2"
    local answer

    while true; do
        if [[ "$default" == "s" ]]; then
            read -rp "$question [S/n]: " answer
            answer="${answer:-s}"
        else
            read -rp "$question [s/N]: " answer
            answer="${answer:-n}"
        fi

        case "$answer" in
            s|S|sim|SIM|Sim) return 0 ;;
            n|N|nao|não|NAO|NÃO|Nao|Não) return 1 ;;
            *) echo "Responda com s ou n." ;;
        esac
    done
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "Execute como root: sudo su"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    else
        err "Não consegui detectar o sistema operacional."
        exit 1
    fi

    log "Sistema detectado: $PRETTY_NAME"
}

install_base_packages() {
    log "Atualizando pacotes e instalando dependências básicas..."

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y curl wget tar unzip ca-certificates gnupg lsb-release software-properties-common nano sudo
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar unzip ca-certificates gnupg nano sudo
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar unzip ca-certificates gnupg nano sudo
    else
        err "Gerenciador de pacotes não suportado automaticamente."
        exit 1
    fi
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker já está instalado."
    else
        log "Docker não encontrado. Instalando Docker automaticamente..."
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    fi

    systemctl enable --now docker
    log "Docker ativado e iniciado."
}

install_wings_binary() {
    log "Criando diretório /etc/pterodactyl..."
    mkdir -p /etc/pterodactyl

    ARCH="$(uname -m)"

    if [[ "$ARCH" == "x86_64" ]]; then
        WINGS_ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        WINGS_ARCH="arm64"
    else
        err "Arquitetura não suportada automaticamente: $ARCH"
        exit 1
    fi

    log "Baixando Wings para arquitetura $WINGS_ARCH..."

    curl -L -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"

    chmod u+x /usr/local/bin/wings

    log "Wings instalado em /usr/local/bin/wings"
}

install_certbot() {
    if command -v certbot >/dev/null 2>&1; then
        log "Certbot já está instalado."
        return
    fi

    log "Instalando Certbot..."

    if command -v apt >/dev/null 2>&1; then
        apt install -y certbot
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release
        yum install -y certbot
    else
        err "Não consegui instalar o Certbot automaticamente."
        exit 1
    fi
}

issue_ssl() {
    echo
    read -rp "Digite o domínio do node/Wings, exemplo node-01.hcraft.cloud: " NODE_DOMAIN

    if [[ -z "$NODE_DOMAIN" ]]; then
        err "Domínio não pode ficar vazio."
        exit 1
    fi

    read -rp "Digite seu e-mail para o SSL/Let's Encrypt: " SSL_EMAIL

    if [[ -z "$SSL_EMAIL" ]]; then
        err "E-mail não pode ficar vazio."
        exit 1
    fi

    warn "A porta 80 precisa estar livre para gerar SSL com standalone."
    warn "Se Nginx, Apache ou outro serviço estiver usando a porta 80, o Certbot pode falhar."

    if ask_yes_no "Quer tentar parar nginx/apache temporariamente?" "n"; then
        systemctl stop nginx 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
        systemctl stop httpd 2>/dev/null || true
    fi

    log "Gerando certificado SSL para $NODE_DOMAIN..."

    certbot certonly --standalone \
        -d "$NODE_DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$SSL_EMAIL"

    log "SSL gerado com sucesso."

    echo
    echo "Certificado:"
    echo "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem"
    echo
    echo "Chave:"
    echo "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem"
    echo
}

setup_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            apt install -y ufw
        else
            warn "UFW não encontrado e instalação automática só foi preparada para Debian/Ubuntu."
            return 0
        fi
    fi

    warn "Liberando portas comuns do Wings..."

    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8080/tcp
    ufw allow 2022/tcp

    if ask_yes_no "Quer ativar o UFW agora?" "n"; then
        ufw --force enable
        log "Firewall ativado."
    else
        warn "Regras adicionadas, mas UFW não foi ativado."
    fi

    ufw status || true
}

install_mariadb_server() {
    if systemctl list-unit-files | grep -qE '^mariadb\.service'; then
        log "MariaDB Server já parece estar instalado."
        systemctl enable --now mariadb
        return 0
    fi

    if systemctl list-unit-files | grep -qE '^mysql\.service'; then
        log "MySQL Server já parece estar instalado."
        systemctl enable --now mysql
        return 0
    fi

    log "Instalando MariaDB Server local..."

    if command -v apt >/dev/null 2>&1; then
        apt install -y mariadb-server mariadb-client
        systemctl enable --now mariadb
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y mariadb-server mariadb
        systemctl enable --now mariadb
    elif command -v yum >/dev/null 2>&1; then
        yum install -y mariadb-server mariadb
        systemctl enable --now mariadb
    else
        warn "Não consegui instalar MariaDB Server automaticamente neste sistema."
        return 0
    fi

    log "MariaDB Server instalado e iniciado."
}

install_mariadb_client_if_needed() {
    if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
        log "Cliente MySQL/MariaDB já encontrado."
        return 0
    fi

    log "Instalando cliente MariaDB/MySQL..."

    if command -v apt >/dev/null 2>&1; then
        apt install -y mariadb-client
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y mariadb
    elif command -v yum >/dev/null 2>&1; then
        yum install -y mariadb
    else
        warn "Não consegui instalar cliente MariaDB automaticamente."
        return 0
    fi
}

get_mysql_command() {
    if command -v mariadb >/dev/null 2>&1; then
        echo "mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        echo "mysql"
    else
        echo ""
    fi
}

get_mysqladmin_command() {
    if command -v mariadb-admin >/dev/null 2>&1; then
        echo "mariadb-admin"
    elif command -v mysqladmin >/dev/null 2>&1; then
        echo "mysqladmin"
    else
        echo ""
    fi
}

setup_database() {
    echo
    warn "Wings não precisa de database própria."
    warn "Essa opção serve para criar uma database para plugins ou servidores."

    if ask_yes_no "Quer instalar MariaDB Server local nesta máquina?" "n"; then
        install_mariadb_server
        DB_HOST_DEFAULT="localhost"
        DB_PORT_DEFAULT="3306"
    else
        DB_HOST_DEFAULT="127.0.0.1"
        DB_PORT_DEFAULT="3306"
    fi

    install_mariadb_client_if_needed

    MYSQL_CMD="$(get_mysql_command)"
    MYSQLADMIN_CMD="$(get_mysqladmin_command)"

    if [[ -z "$MYSQL_CMD" ]]; then
        warn "Cliente MySQL/MariaDB não encontrado. Pulando criação da database."
        return 0
    fi

    read -rp "Host do MySQL/MariaDB [$DB_HOST_DEFAULT]: " DB_HOST
    DB_HOST="${DB_HOST:-$DB_HOST_DEFAULT}"

    read -rp "Porta do MySQL/MariaDB [$DB_PORT_DEFAULT]: " DB_PORT
    DB_PORT="${DB_PORT:-$DB_PORT_DEFAULT}"

    read -rp "Usuário admin do banco [root]: " DB_ADMIN_USER
    DB_ADMIN_USER="${DB_ADMIN_USER:-root}"

    read -rsp "Senha do usuário $DB_ADMIN_USER, deixe vazio se for root local sem senha: " DB_ADMIN_PASS
    echo

    read -rp "Nome da database que deseja criar: " NEW_DB_NAME
    read -rp "Nome do usuário da database: " NEW_DB_USER
    read -rsp "Senha para o usuário $NEW_DB_USER: " NEW_DB_PASS
    echo

    read -rp "Host permitido para o usuário [%]: " NEW_DB_ALLOWED_HOST
    NEW_DB_ALLOWED_HOST="${NEW_DB_ALLOWED_HOST:-%}"

    if [[ -z "$NEW_DB_NAME" || -z "$NEW_DB_USER" || -z "$NEW_DB_PASS" ]]; then
        err "Nome da database, usuário e senha não podem ficar vazios."
        warn "Pulando criação da database."
        return 0
    fi

    log "Testando conexão com o banco em $DB_HOST:$DB_PORT..."

    DB_PASS_ARG=()
    if [[ -n "$DB_ADMIN_PASS" ]]; then
        DB_PASS_ARG=(-p"$DB_ADMIN_PASS")
    fi

    if [[ -n "$MYSQLADMIN_CMD" ]]; then
        if ! "$MYSQLADMIN_CMD" ping -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ADMIN_USER" "${DB_PASS_ARG[@]}" --silent; then
            err "Não foi possível conectar no banco em $DB_HOST:$DB_PORT"
            warn "A instalação do Wings vai continuar sem criar a database."
            warn "Confira se o MariaDB/MySQL está ligado, se a porta está correta e se o host está correto."
            return 0
        fi
    fi

    SQL="
CREATE DATABASE IF NOT EXISTS \`$NEW_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$NEW_DB_USER'@'$NEW_DB_ALLOWED_HOST' IDENTIFIED BY '$NEW_DB_PASS';
GRANT ALL PRIVILEGES ON \`$NEW_DB_NAME\`.* TO '$NEW_DB_USER'@'$NEW_DB_ALLOWED_HOST';
FLUSH PRIVILEGES;
"

    log "Criando database e usuário..."

    if "$MYSQL_CMD" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ADMIN_USER" "${DB_PASS_ARG[@]}" -e "$SQL"; then
        log "Database criada com sucesso."

        echo
        echo "Database: $NEW_DB_NAME"
        echo "Usuário: $NEW_DB_USER"
        echo "Host permitido: $NEW_DB_ALLOWED_HOST"
        echo
    else
        err "Falha ao criar database ou usuário."
        warn "A instalação do Wings vai continuar mesmo assim."
        return 0
    fi
}

create_wings_service() {
    log "Criando serviço systemd do Wings..."

    cat > /etc/systemd/system/wings.service <<'EOF'
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
EOF

    systemctl daemon-reload
    log "Serviço systemd criado."
}

check_wings_config() {
    if [[ -f /etc/pterodactyl/config.yml && -s /etc/pterodactyl/config.yml ]]; then
        chmod 600 /etc/pterodactyl/config.yml
        log "Config do Wings encontrada em /etc/pterodactyl/config.yml"
        return 0
    fi

    warn "Config do Wings não encontrada em /etc/pterodactyl/config.yml"
    warn "O Wings foi instalado, mas não será iniciado enquanto a config não existir."
    return 1
}

start_wings() {
    if ! check_wings_config; then
        return 0
    fi

    log "Iniciando Wings..."

    systemctl enable --now wings
    sleep 2
    systemctl status wings --no-pager || true
}

main() {
    clear

    echo -e "${BLUE}"
    echo "======================================"
    echo " Instalador Interativo Pterodactyl Wings"
    echo "======================================"
    echo -e "${RESET}"

    echo "Log da instalação:"
    echo "$LOG_FILE"
    echo

    check_root
    detect_os
    install_base_packages
    install_docker
    install_wings_binary

    if ask_yes_no "Quer gerar SSL com Certbot para o domínio do node?" "s"; then
        install_certbot
        issue_ssl
    fi

    if ask_yes_no "Quer configurar firewall UFW com portas do Wings?" "n"; then
        setup_firewall
    fi

    if ask_yes_no "Quer criar uma database MySQL/MariaDB opcional?" "n"; then
        setup_database
    fi

    create_wings_service
    start_wings

    log "Instalação finalizada."
    echo "Log salvo em: $LOG_FILE"
    echo
    echo "Para ver o log da instalação:"
    echo "tail -f $LOG_FILE"
    echo
    echo "Para ver logs do Wings:"
    echo "journalctl -u wings -f"
}

main
