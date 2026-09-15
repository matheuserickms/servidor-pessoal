#!/usr/bin/env bash
# =============================================================================
# Envia o MOLDE (este repo) para o servidor, sem tocar no estado vivo.
#
#   ./deploy-infra.sh matheus@1.2.3.4
#
# O que sobe:   infra/compose.yml, infra/Caddyfile, scripts/, templates/
# O que NÃO sobe, nunca:
#   - /opt/stacks/_infra/.env         (senha do banco, gerada no servidor)
#   - /opt/stacks/_infra/sites/*.caddy (rotas dos projetos, geradas lá)
#   - /opt/stacks/<projeto>/          (os projetos em si)
#   - scripts/oci.env                  (OCIDs da tenancy, só serve no notebook)
#
# Rode do seu notebook, de dentro do repo.
# =============================================================================
set -euo pipefail

DESTINO="${1:-}"
[[ -n "$DESTINO" ]] || {
	echo "uso: $0 <usuario>@<host>" >&2
	exit 1
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "==> preparando diretórios em $DESTINO"
ssh "$DESTINO" 'mkdir -p /opt/stacks/_infra/sites ~/servidor'

echo "==> enviando molde da infraestrutura"
scp infra/compose.yml infra/Caddyfile infra/.env.example "$DESTINO:/opt/stacks/_infra/"

# O placeholder só precisa existir; se já está lá, não mexe (evita sobrescrever
# por engano algo que você tenha editado no servidor).
ssh "$DESTINO" 'test -e /opt/stacks/_infra/sites/_placeholder.caddy' ||
	scp infra/sites/_placeholder.caddy "$DESTINO:/opt/stacks/_infra/sites/"

echo "==> enviando scripts, templates e units do systemd"
scp -r scripts templates systemd "$DESTINO:~/servidor/"
ssh "$DESTINO" 'chmod +x ~/servidor/scripts/*.sh'

# scripts/oci.env tem os OCIDs da tenancy — só serve para criar-instancia.sh,
# que só roda do notebook. Não tem função nenhuma no servidor; melhor não
# deixar rastro dele lá.
ssh "$DESTINO" 'rm -f ~/servidor/scripts/oci.env'

# O .env do servidor pode não existir ainda (primeiro deploy).
if ! ssh "$DESTINO" 'test -s /opt/stacks/_infra/.env'; then
	echo
	echo "  ATENÇÃO: /opt/stacks/_infra/.env não existe ou está vazio."
	echo "  Antes de subir a stack, no servidor:"
	echo "    cd /opt/stacks/_infra"
	echo "    cp .env.example .env && chmod 600 .env"
	echo "    openssl rand -base64 32   # senha do postgres"
	echo "    nano .env"
	echo
	exit 0
fi

echo
read -rp "Aplicar agora no servidor (compose up -d + reload do Caddy)? [s/N] " OK
if [[ "${OK,,}" == "s" ]]; then
	ssh "$DESTINO" '
		set -e
		cd /opt/stacks/_infra
		docker compose up -d
		docker compose exec -T caddy caddy reload -c /etc/caddy/Caddyfile
		docker compose ps
	'
else
	cat <<-FIM

		nada aplicado. para aplicar depois, no servidor:
		  cd /opt/stacks/_infra
		  docker compose up -d
		  docker compose exec caddy caddy reload -c /etc/caddy/Caddyfile
	FIM
fi

cat <<-FIM

	nota: os scripts de backup vivem em /usr/local/bin e não são atualizados
	por este deploy. se você mudou backup.sh ou restore.sh, no servidor:
	  sudo cp ~/servidor/scripts/backup.sh ~/servidor/scripts/restore*.sh /usr/local/bin/
	  sudo chmod 700 /usr/local/bin/backup.sh /usr/local/bin/restore*.sh
FIM
