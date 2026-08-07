#!/usr/bin/env bash
# =============================================================================
# Restaura /opt/stacks a partir do restic — os compose dos projetos, os
# arquivos de rota do Caddy e, principalmente, os .env com as senhas dos
# databases.
#
#   ./restore-stacks.sh                 # baixa para uma área de staging
#   ./restore-stacks.sh --in-place      # escreve direto em /opt/stacks
#
# Sob o modelo "repo como molde", este é o par obrigatório do restore.sh:
# aquele traz os DADOS, este traz a CONFIGURAÇÃO. Sem os dois, o servidor
# não volta.
#
# Destino no servidor: /usr/local/bin/restore-stacks.sh
# =============================================================================
set -euo pipefail

STAGING=/var/backups/restore-stacks
IN_PLACE=false

[[ "${1:-}" == "--in-place" ]] && IN_PLACE=true

# shellcheck source=/dev/null
source /etc/backup.env

log() { echo "[$(date -Is)] $*"; }

if $IN_PLACE; then
	echo
	echo "  ATENÇÃO: isto sobrescreve arquivos em /opt/stacks com a versão do"
	echo "  backup. Alterações feitas depois do último backup serão perdidas."
	echo
	read -rp "  Digite o hostname deste servidor para confirmar: " CONFIRMACAO
	[[ "$CONFIRMACAO" == "$(hostname)" ]] || {
		echo "cancelado."
		exit 1
	}
	ALVO=/
else
	rm -rf "$STAGING"
	mkdir -p "$STAGING"
	ALVO="$STAGING"
fi

log "restaurando snapshot mais recente com a tag 'stacks'"
restic restore latest --tag stacks --target "$ALVO"

if $IN_PLACE; then
	# Os .env carregam senha de banco; o restic preserva permissões, mas
	# reforçar aqui é barato.
	find /opt/stacks -name '.env' -exec chmod 600 {} +
	chown -R matheus:matheus /opt/stacks
	log "restaurado em /opt/stacks"
	cat <<-FIM

		próximo passo: subir tudo de novo.
		  cd /opt/stacks/_infra && docker compose up -d
		  for d in /opt/stacks/*/; do
		    [ "$d" = /opt/stacks/_infra/ ] && continue
		    (cd "$d" && docker compose up -d)
		  done
	FIM
else
	log "restaurado em $STAGING (nada foi sobrescrito)"
	cat <<-FIM

		revise o conteúdo e copie o que quiser:
		  ls -la $STAGING/opt/stacks/
		  cp -a $STAGING/opt/stacks/<projeto> /opt/stacks/

		ou rode de novo com --in-place para sobrescrever tudo de uma vez.
	FIM
fi
