# Wings Installer

Instalador interativo para **Pterodactyl Wings** com Docker, serviço systemd, SSL opcional e configuração opcional de firewall.

## O que ele faz

- Detecta a arquitetura (`amd64` ou `arm64`) e baixa a versão estável mais recente do Wings.
- Instala e habilita o Docker no boot.
- Cria o serviço `wings.service` e **habilita o Wings para iniciar automaticamente após reinicializações**.
- Preserva `/etc/pterodactyl/config.yml` em reinstalações/atualizações.
- Faz backup do binário anterior do Wings antes de substituí-lo.
- Pode emitir SSL com Certbot e instala um hook para reiniciar o Wings após renovações do certificado.
- Pode configurar UFW com as portas da API e SFTP do Wings.
- Salva o log da instalação em `/var/log/wings-installer.log`.

## Sistemas

O instalador é voltado para distribuições Linux com `systemd`, principalmente Ubuntu/Debian e RHEL/Rocky/AlmaLinux.

> Wings depende de Docker. Ambientes LXC/OpenVZ podem exigir suporte a nesting do provedor.

## Uso rápido

Execute como `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jaxdesu/wings-installer/refs/heads/main/main/install.sh)
```

Depois, coloque a configuração gerada pelo painel em:

```text
/etc/pterodactyl/config.yml
```

Se a configuração já existir durante a instalação, o Wings será iniciado automaticamente. Caso ainda não exista, o serviço continuará habilitado para o próximo boot e pode ser iniciado depois com:

```bash
systemctl start wings
```

## Comandos úteis

```bash
systemctl status wings --no-pager
systemctl is-enabled wings
journalctl -u wings -f
```

## Atualização

O instalador também pode ser executado novamente em um node existente. Ele preserva a configuração, cria um backup do binário atual e instala a versão estável mais recente do Wings.
