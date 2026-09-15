#!/usr/bin/env bash
# =============================================================================
# Provisionamento manual — alternativa ao cloud-init.yaml.
#
# Use quando a instância foi criada SEM o initialization script. Faz
# exatamente o que o cloud-init.yaml faria, na mesma ordem.
#
#   scp scripts/provisionar.sh ubuntu@IP:~
#   ssh ubuntu@IP 'sudo bash ~/provisionar.sh'
#
# Idempotente: pode rodar de novo sem quebrar nada.
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rode com sudo" >&2; exit 1; }

USUARIO=matheus
CHAVE_ORIGEM=/home/ubuntu/.ssh/authorized_keys

echo "==> 1/9 expandindo o filesystem para o tamanho do boot volume"
if [[ -x /usr/libexec/oci-growfs ]]; then
	/usr/libexec/oci-growfs -y
else
	apt-get update -qq && apt-get install -y -qq cloud-guest-utils
	ROOT_SRC="$(findmnt -no SOURCE /)"
	DISCO="$(lsblk -no PKNAME "$ROOT_SRC" | tr -d ' ')"
	PART="$(echo "$ROOT_SRC" | grep -o '[0-9]*$')"
	if [[ -n "$DISCO" && -n "$PART" ]]; then
		growpart "/dev/$DISCO" "$PART" || true
		resize2fs "$ROOT_SRC" || true
	fi
fi
df -h /

echo "==> 2/9 criando o usuário $USUARIO"
if ! id "$USUARIO" &>/dev/null; then
	groupadd -f docker
	useradd -m -s /bin/bash -c "Matheus" -G sudo,docker "$USUARIO"
	passwd -l "$USUARIO"
fi
install -d -m 700 -o "$USUARIO" -g "$USUARIO" "/home/$USUARIO/.ssh"
# A chave vem do usuário ubuntu, que a recebeu do console na criação.
[[ -f "$CHAVE_ORIGEM" ]] || { echo "ERRO: $CHAVE_ORIGEM não existe" >&2; exit 1; }
install -m 600 -o "$USUARIO" -g "$USUARIO" "$CHAVE_ORIGEM" "/home/$USUARIO/.ssh/authorized_keys"
echo "$USUARIO ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USUARIO"
chmod 440 "/etc/sudoers.d/90-$USUARIO"
visudo -c >/dev/null

echo "==> 3/9 instalando pacotes base"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
	ca-certificates curl gnupg git ufw fail2ban unattended-upgrades \
	restic htop ncdu jq cloud-guest-utils

echo "==> 4/9 arquivos de configuração"
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
CONF

# No Ubuntu 24.04 o sshd loga no journald: sem "backend = systemd" o jail
# sobe mas nunca bane ninguém.
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<'CONF'
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
CONF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF

cat > /etc/apt/apt.conf.d/50unattended-upgrades-local <<'CONF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
CONF

cat > /etc/sysctl.d/99-servidor.conf <<'CONF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
net.core.somaxconn = 1024
CONF

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'CONF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
CONF

echo "==> 5/9 removendo o iptables da imagem da Oracle"
# A imagem do OCI aplica REJECT em tudo menos 22, por fora do ufw.
# Roda ANTES do Docker: o flush apagaria as chains que o Docker cria.
systemctl stop netfilter-persistent 2>/dev/null || true
systemctl disable netfilter-persistent 2>/dev/null || true
apt-get purge -y netfilter-persistent iptables-persistent 2>/dev/null || true
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
for cmd in iptables ip6tables; do
	$cmd -P INPUT ACCEPT
	$cmd -P FORWARD ACCEPT
	$cmd -P OUTPUT ACCEPT
	$cmd -F
	$cmd -X
done

echo "==> 6/9 ufw"
# O Docker escreve iptables por fora do ufw: uma porta publicada com `ports:`
# fica exposta mesmo com o ufw negando. A defesa real é a Security List do
# VCN, fora da VM. Regra de ouro: só o Caddy usa `ports:`.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http'
ufw allow 443/tcp comment 'https'
ufw allow 443/udp comment 'http3'
ufw --force enable

echo "==> 7/9 swap"
if [[ ! -f /swapfile ]]; then
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile
	echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl --system

echo "==> 8/9 Docker Engine + Compose plugin"
if ! command -v docker &>/dev/null; then
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
		> /etc/apt/sources.list.d/docker.list
	apt-get update
	apt-get install -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$USUARIO"
systemctl enable --now docker

echo "==> 9/9 redes docker, diretórios e serviços"
docker network create edge 2>/dev/null || true
docker network create data 2>/dev/null || true
mkdir -p /opt/stacks /var/backups/postgres
chown -R "$USUARIO:$USUARIO" /opt/stacks
chmod 700 /var/backups/postgres
systemctl restart ssh
systemctl enable --now fail2ban

echo
echo "================================================================"
echo "  Provisionamento concluído."
echo "  Teste agora, de OUTRO terminal, ANTES de fechar esta sessão:"
echo "      ssh $USUARIO@<IP>"
echo "  Se falhar, você ainda está conectado como ubuntu para corrigir."
echo "================================================================"
