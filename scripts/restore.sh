#!/usr/bin/env bash
# =============================================================================
# Restaura o Postgres a partir de um snapshot do restic.
#
#   ./restore.sh              # usa o snapshot mais recente
#   ./restore.sh a1b2c3d4     # usa um snapshot específico
#   restic snapshots --tag postgres   # para listar
#
# DESTRUTIVO: o dump é feito com --clean, então ele DERRUBA os objetos atuais
# antes de recriar. Exige confirmação digitada.
#
# Rode isto de propósito pelo menos uma vez, num domingo à tarde, antes de
# precisar. Backup nunca restaurado é fé, não backup.
# =============================================================================
set -euo pipefail

INFRA_DIR=/opt/stacks/_infra
TRABALHO=/var/backups/restore

# shellcheck source=/dev/null
source /etc/backup.env

SNAPSHOT="${1:-latest}"

log() { echo "[$(date -Is)] $*"; }

echo
echo "  ATENÇÃO: isto substitui TODOS os databases do servidor pelo conteúdo"
echo "  do snapshot '$SNAPSHOT'. Dados gravados depois dele serão perdidos."
echo
read -rp "  Digite o hostname deste servidor para confirmar: " CONFIRMACAO
[[ "$CONFIRMACAO" == "$(hostname)" ]] || {
	echo "cancelado."
	exit 1
}

rm -rf "$TRABALHO"
mkdir -p "$TRABALHO"

log "baixando snapshot $SNAPSHOT"
restic restore "$SNAPSHOT" --tag postgres --target "$TRABALHO"

ARQUIVO="$(find "$TRABALHO" -name 'pg-*.sql.gz' -print -quit)"
[[ -n "$ARQUIVO" ]] || {
	echo "nenhum dump encontrado no snapshot" >&2
	exit 1
}
log "dump: $ARQUIVO"

# Verifica se o gzip está íntegro ANTES de derrubar qualquer coisa.
gzip -t "$ARQUIVO" || {
	echo "dump corrompido — abortando sem tocar no banco" >&2
	exit 1
}

log "aplicando no postgres"
gunzip -c "$ARQUIVO" |
	docker compose -f "$INFRA_DIR/compose.yml" exec -T postgres \
		psql -U postgres -v ON_ERROR_STOP=0 -d postgres

# ON_ERROR_STOP=0 de propósito: pg_dumpall --clean gera DROPs de objetos que
# podem não existir num banco vazio, e esses erros são esperados e inofensivos.

log "restore concluído — confira as aplicações antes de considerar resolvido"
rm -rf "$TRABALHO"
