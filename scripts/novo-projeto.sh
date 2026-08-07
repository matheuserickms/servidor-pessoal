#!/usr/bin/env bash
# =============================================================================
# Cria um projeto novo: database + role dedicados no Postgres, diretório do
# stack a partir do template e a entrada de proxy no Caddy.
#
#   ./novo-projeto.sh meu-blog
#
# Idempotente o suficiente para ser seguro: aborta se o diretório do stack já
# existir, e não recria database/role que já existam.
# =============================================================================
set -euo pipefail

STACKS_DIR=/opt/stacks
INFRA_DIR="$STACKS_DIR/_infra"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/projeto-exemplo" && pwd)"

erro() {
	echo "erro: $*" >&2
	exit 1
}

PROJETO="${1:-}"
[[ -n "$PROJETO" ]] || erro "uso: $0 <slug-do-projeto>"

# Slug restrito: vira nome de database, de role e de subdomínio.
[[ "$PROJETO" =~ ^[a-z][a-z0-9-]{1,30}$ ]] ||
	erro "slug inválido: use minúsculas, números e hífen, começando por letra"

[[ -d "$STACKS_DIR/$PROJETO" ]] && erro "$STACKS_DIR/$PROJETO já existe"
[[ -d "$INFRA_DIR" ]] || erro "stack de infra não encontrado em $INFRA_DIR"

# Role e database usam underscore: hífen exigiria aspas em toda query.
DB_NAME="${PROJETO//-/_}"
DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

echo "==> criando database e role '$DB_NAME'"
docker compose -f "$INFRA_DIR/compose.yml" exec -T postgres \
	psql -U postgres -v ON_ERROR_STOP=1 <<-SQL
		SELECT 'CREATE ROLE $DB_NAME LOGIN PASSWORD ''$DB_PASS'''
		 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_NAME')\gexec

		SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_NAME'
		 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

		REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;
	SQL

echo "==> montando $STACKS_DIR/$PROJETO"
mkdir -p "$STACKS_DIR/$PROJETO"
sed "s/PROJETO/$PROJETO/g" "$TEMPLATE_DIR/compose.yml" >"$STACKS_DIR/$PROJETO/compose.yml"

sed -e "s|postgres://PROJETO:SENHA_AQUI@postgres:5432/PROJETO|postgres://$DB_NAME:$DB_PASS@postgres:5432/$DB_NAME|" \
	-e "s/PROJETO/$PROJETO/g" \
	"$TEMPLATE_DIR/.env.example" >"$STACKS_DIR/$PROJETO/.env"
chmod 600 "$STACKS_DIR/$PROJETO/.env"

echo "==> registrando proxy em $INFRA_DIR/sites/$PROJETO.caddy"
sed "s/PROJETO/$PROJETO/g" "$TEMPLATE_DIR/site.caddy" >"$INFRA_DIR/sites/$PROJETO.caddy"

cat <<-FIM

	pronto.

	falta você:
	  1. editar $STACKS_DIR/$PROJETO/compose.yml  (a imagem e a porta interna)
	  2. conferir $STACKS_DIR/$PROJETO/.env
	  3. subir:    cd $STACKS_DIR/$PROJETO && docker compose up -d
	  4. recarregar o proxy:
	       cd $INFRA_DIR && docker compose exec caddy caddy reload -c /etc/caddy/Caddyfile

	o site responde em https://$PROJETO.<seu-dominio> assim que o DNS resolver.
	a senha do banco já está no .env — ela não é recuperável depois, então não
	apague o arquivo sem guardar.
FIM
