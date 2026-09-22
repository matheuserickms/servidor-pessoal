#!/usr/bin/env bash
# =============================================================================
# Backup diário: dump lógico do Postgres + configuração dos stacks, enviados
# criptografados para um bucket fora do provedor.
#
# Destino no servidor: /usr/local/bin/backup.sh   (root:root, chmod 700)
# Disparado pelo systemd timer (ver systemd/backup.timer).
#
# Por que dump lógico e não snapshot do provedor: snapshot mora na mesma conta
# que pode ser suspensa ou perdida. Backup que compartilha o ponto de falha do
# original não é backup.
#
# MODO LOCAL: sem /etc/backup.env o script não aborta — faz o dump e um tar da
# configuração dos stacks em /var/backups e avisa alto que NÃO há cópia fora do
# servidor. Isso cobre erro humano e migration ruim (que é o que mais acontece),
# não a perda do servidor. É estado provisório: crie o bucket e o
# /etc/backup.env, e o mesmo script passa a enviar sem mais nenhuma mudança.
# =============================================================================
set -euo pipefail

INFRA_DIR=/opt/stacks/_infra
DUMP_DIR=/var/backups/postgres
RETENCAO_DIARIA=7
RETENCAO_SEMANAL=4
TAMANHO_MINIMO_DUMP=1024 # bytes; abaixo disso o dump é lixo

# RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
if [[ -f /etc/backup.env ]]; then
	# shellcheck source=/dev/null
	source /etc/backup.env
	OFFSITE=1
else
	OFFSITE=0
fi

log() { echo "[$(date -Is)] $*"; }
falha() {
	log "FALHA: $*"
	exit 1
}

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
DUMP="$DUMP_DIR/pg-$STAMP.sql.gz"

# ---------------------------------------------------------------------------
# 1. Dump de todos os databases, rodando DENTRO do container.
#    Isso evita instalar o client no host e garante que a versão do pg_dumpall
#    é exatamente a do servidor (client mais antigo se recusa a dumpar).
#    O pipefail acima faz a falha do pg_dumpall derrubar o script mesmo com
#    o gzip terminando com sucesso.
# ---------------------------------------------------------------------------
log "dump do postgres"
docker compose -f "$INFRA_DIR/compose.yml" exec -T postgres \
	pg_dumpall -U postgres --clean --if-exists |
	gzip -9 >"$DUMP" || falha "pg_dumpall falhou"

TAMANHO="$(stat -c%s "$DUMP")"
[[ "$TAMANHO" -ge "$TAMANHO_MINIMO_DUMP" ]] ||
	falha "dump com $TAMANHO bytes — pequeno demais para ser real"
log "dump ok ($((TAMANHO / 1024)) KB)"

# ---------------------------------------------------------------------------
# 2. Sem bucket configurado: guarda o que dá localmente e sai avisando.
# ---------------------------------------------------------------------------
if [[ "$OFFSITE" -eq 0 ]]; then
	STACKS_TAR="$DUMP_DIR/stacks-$STAMP.tar.gz"
	log "empacotando /opt/stacks (configs, .env dos projetos e sessions do bot)"
	tar -czf "$STACKS_TAR" \
		--exclude='*.log' --exclude='node_modules' --exclude='.git' \
		--exclude='opt/stacks/*/src' \
		-C / opt/stacks || falha "tar dos stacks falhou"

	find "$DUMP_DIR" -name 'pg-*.sql.gz' -mtime +"$RETENCAO_DIARIA" -delete
	find "$DUMP_DIR" -name 'stacks-*.tar.gz' -mtime +"$RETENCAO_DIARIA" -delete

	log "ok: $(du -h "$DUMP" | cut -f1) banco + $(du -h "$STACKS_TAR" | cut -f1) stacks em $DUMP_DIR"
	log "AVISO: SEM CÓPIA FORA DO SERVIDOR. /etc/backup.env não existe — se este"
	log "       servidor for perdido, este backup vai junto. Ver passo 7 do README."
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. Inicializa o repositório restic na primeira execução.
# ---------------------------------------------------------------------------
if ! restic cat config >/dev/null 2>&1; then
	log "repositório restic ainda não existe, inicializando"
	restic init
fi

# ---------------------------------------------------------------------------
# 4. Envia. Dois conjuntos separados: o banco e a configuração dos stacks
#    (compose, Caddyfile, .env). Restaurar exige os dois.
# ---------------------------------------------------------------------------
log "enviando dump"
restic backup "$DUMP" --tag postgres

log "enviando configuração dos stacks"
# */src é código enviado por rsync no deploy (o caosBot faz isso) — vive no
# git e seria peso morto aqui. O que importa em /opt/stacks é o que NÃO está
# versionado: os .env com as senhas dos databases e o sessions/ do bot.
restic backup /opt/stacks --tag stacks \
	--exclude='*.log' \
	--exclude='**/node_modules' \
	--exclude='**/.git' \
	--exclude='/opt/stacks/*/src'

# ---------------------------------------------------------------------------
# 5. Retenção e verificação de integridade dos metadados.
#    A verificação pesada (--read-data-subset) fica mensal, no README —
#    fazer todo dia gastaria banda e tempo sem ganho proporcional.
# ---------------------------------------------------------------------------
log "aplicando retenção"
restic forget \
	--keep-daily "$RETENCAO_DIARIA" \
	--keep-weekly "$RETENCAO_SEMANAL" \
	--prune

log "verificando repositório"
restic check

# Dumps locais servem só de cache para restore rápido; o que vale está remoto.
find "$DUMP_DIR" -name 'pg-*.sql.gz' -mtime +2 -delete

# ---------------------------------------------------------------------------
# 6. Avisa o monitor de que o backup terminou.
#
#    Sem /opt/stacks no git, um backup que para silenciosamente leva junto as
#    senhas dos databases — geradas aleatoriamente e sem cópia em outro lugar.
#    O ping só acontece aqui, DEPOIS de tudo ter dado certo: qualquer falha
#    acima aborta o script pelo `set -e` e o monitor deixa de receber sinal,
#    que é exatamente o alarme que se quer.
#
#    Crie um monitor do tipo "Push" no Uptime Kuma e ponha a URL dele em
#    BACKUP_PING_URL, dentro de /etc/backup.env.
# ---------------------------------------------------------------------------
if [ -n "${BACKUP_PING_URL:-}" ]; then
	if curl -fsS --max-time 10 "$BACKUP_PING_URL" >/dev/null; then
		log "monitor avisado"
	else
		# Não falha o backup por causa disto: o backup está feito e íntegro.
		# O silêncio no Kuma já sinaliza que algo precisa de atenção.
		log "AVISO: backup ok, mas o ping para o monitor falhou"
	fi
else
	log "AVISO: BACKUP_PING_URL não definida — nada vai te avisar se este backup parar"
fi

log "concluído"
