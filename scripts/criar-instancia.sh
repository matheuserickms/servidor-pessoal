#!/usr/bin/env bash
# =============================================================================
# Cria a instância A1 no OCI, insistindo até haver capacidade.
#
# "Out of host capacity" em região de AD único (como sa-saopaulo-1) não tem
# contorno: só resta tentar de novo até alguém liberar um host. Este script
# faz isso sozinho, tentando 1 OCPU/6 GB antes de 2 OCPU/12 GB — o pedido
# menor cabe em mais lugares e costuma sair primeiro.
#
#   ./scripts/criar-instancia.sh                 # insiste indefinidamente
#   INTERVALO=120 ./scripts/criar-instancia.sh   # a cada 2 min
#   TENTATIVAS=20 ./scripts/criar-instancia.sh   # desiste depois de 20 ciclos
#
# Qualquer erro que NÃO seja falta de capacidade aborta na hora — um erro de
# permissão ou de limite de serviço não melhora com repetição.
#
# Auditoria de 2026-09-10 (subagente fable, com dados reais do log e da API):
# o `oci compute instance launch` sem --no-retry já retentava 5xx internamente
# (7x, até ~100s por chamada), inflando cada "tentativa" do log em ~8
# requisições reais e gerando 429 ("Too many requests"). Com --no-retry cada
# chamada cai para ~2s. Antes de cada launch de verdade, uma sonda barata via
# `compute-capacity-report` (endpoint separado, não conta como launch) decide
# se vale a pena tentar — mas a cada FORCAR_A_CADA ciclos o launch acontece
# mesmo que o relatório diga "sem capacidade", porque ele pode não refletir
# 100% o pool do Always Free.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Trava contra execução concorrente: duas cópias rodando podem criar DUAS
# instâncias quando a capacidade aparecer, estourando o Always Free.
# Fica dentro do repo (não em /tmp) porque o systemd-tmpfiles limpa /tmp
# depois de 30 dias parados — e este script pode rodar por mais tempo que isso.
#
# CUIDADO: todo comando externo (oci, sleep) filho deste processo HERDA o fd 9
# por padrão. Um `kill -TERM` no script mata só o bash — se nesse instante
# houver um `sleep` ou `oci` em andamento, ele continua rodando órfão
# segurando a trava, e um restart imediato falha com "já existe uma execução
# em andamento" mesmo sem loop nenhum de fato rodando (visto na prática em
# 2026-09-10: um `sleep 180` órfão segurou o lock). Por isso TODO comando
# externo abaixo fecha o fd com `9>&-`.
TRAVA="$REPO/.criar-instancia.lock"
exec 9>"$TRAVA"
if ! flock -n 9; then
	echo "erro: já existe uma execução em andamento (trava $TRAVA)." >&2
	echo "      veja o progresso com: tail -f criar-instancia.log" >&2
	exit 3
fi

OCI="${OCI:-$HOME/.local/share/oci-cli-venv/bin/oci}"
INTERVALO="${INTERVALO:-45}"    # segundos entre ciclos completos
TENTATIVAS="${TENTATIVAS:-0}"   # 0 = sem limite
NOME="${NOME:-srv01}"
DISCO_GB="${DISCO_GB:-100}"
CHAVE_PUB="${CHAVE_PUB:-$HOME/.ssh/id_ed25519.pub}"
CLOUD_INIT="$REPO/cloud-init.yaml"
LOG="$REPO/criar-instancia.log"

# Configurações tentadas em cada ciclo, na ordem: "<ocpus> <memoria_gb>"
CONFIGS=("1 6" "2 12")

# A cada N ciclos, tenta o launch de verdade mesmo que a sonda de capacidade
# (compute-capacity-report) diga que não há host — ela é informativa, não
# garantida 100% fiel ao pool do Always Free.
FORCAR_A_CADA="${FORCAR_A_CADA:-5}"

# Erros que NÃO melhoram com repetição — só estes abortam o loop.
# Tudo o mais (timeout, DNS, 5xx, rede caindo na suspensão do notebook) é
# transitório e merece nova tentativa.
FATAIS='NotAuthenticated|NotAuthorized|LimitExceeded|QuotaExceeded|CannotParseRequest|InvalidParameter|MissingParameter|is not authorized to perform'
MAX_ERROS_SEGUIDOS="${MAX_ERROS_SEGUIDOS:-15}"

export SUPPRESS_LABEL_WARNING=True

# --- validações antes de começar ---------------------------------------------
[[ -x "$OCI" ]] || { echo "erro: oci não encontrado em $OCI" >&2; exit 1; }
[[ -f "$CHAVE_PUB" ]] || { echo "erro: chave pública não encontrada: $CHAVE_PUB" >&2; exit 1; }
[[ -f "$CLOUD_INIT" ]] || { echo "erro: cloud-init.yaml não encontrado" >&2; exit 1; }
[[ -f "$REPO/scripts/oci.env" ]] || {
	echo "erro: scripts/oci.env não existe. Copie de oci.env.example e preencha." >&2
	exit 1
}
# shellcheck source=/dev/null
source "$REPO/scripts/oci.env"
for v in OCI_COMPARTMENT_ID OCI_AVAILABILITY_DOMAIN OCI_SUBNET_ID OCI_IMAGE_ID; do
	[[ -n "${!v:-}" ]] || { echo "erro: $v vazio em scripts/oci.env" >&2; exit 1; }
done

# Falha cedo se o YAML estiver inválido: descobrir isso depois de horas de
# espera, com a instância já criada e quebrada, é o pior desfecho possível.
if command -v python3 >/dev/null; then
	python3 -c "import yaml,sys; yaml.safe_load(open('$CLOUD_INIT'))" 2>/dev/null || {
		echo "erro: $CLOUD_INIT não é YAML válido" >&2
		exit 1
	}
fi

registrar() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

avisar() {
	command -v notify-send >/dev/null && notify-send "$1" "$2" 2>/dev/null || true
}

# Extrai o OCID da instância de QUALQUER LUGAR da saída do `oci`, JSON válido
# ou não. Isso importa porque `--wait-for-state` cria a instância e SÓ DEPOIS
# fica esperando ela ficar RUNNING — se essa espera falhar (rede caiu, rate
# limit, notebook suspendeu), a CLI sai com código != 0 mesmo com a instância
# já existindo, e a mensagem de erro não bate com "capacity" nem com $FATAIS.
# Sem isto, o loop trataria isso como "não criou, tenta de novo" e criaria
# uma segunda instância.
extrair_ocid() {
	grep -oE '"id"[[:space:]]*:[[:space:]]*"ocid1\.instance\.[^"]+"' \
		| head -1 \
		| sed -E 's/.*"(ocid1\.instance\.[^"]+)".*/\1/'
}

# Sonda a disponibilidade de capacidade via compute-capacity-report: um
# endpoint de LEITURA (~2s, não conta como tentativa de launch) que a própria
# Oracle recomenda consultar antes de criar. Devolve o texto do
# "availability-status" (ex.: AVAILABLE, OUT_OF_HOST_CAPACITY) ou vazio se a
# consulta falhar — vazio é tratado como "inconclusivo" pelo chamador, nunca
# como "sem capacidade".
sondar_capacidade() {
	local ocpus="$1" mem="$2"
	timeout 20 "$OCI" compute compute-capacity-report create \
		--compartment-id "$OCI_COMPARTMENT_ID" \
		--availability-domain "$OCI_AVAILABILITY_DOMAIN" \
		--shape-availabilities "[{\"instanceShape\":\"VM.Standard.A1.Flex\",\"instanceShapeConfig\":{\"ocpus\":${ocpus},\"memoryInGBs\":${mem}}}]" \
		--query 'data."shape-availabilities"[0]."availability-status"' \
		--raw-output 2>/dev/null 9>&-
}

# Estado atual da instância pelo OCID. Existe porque o launch pode devolver
# um OCID válido (estado PROVISIONING) e a instância morrer logo depois
# (Oracle aceita o pedido e falha o placement) — sem isso o script declararia
# sucesso e sairia com uma instância morta na mão.
estado_instancia() {
	local id="$1"
	timeout 30 "$OCI" compute instance get --instance-id "$id" \
		--query 'data."lifecycle-state"' --raw-output 2>/dev/null 9>&-
}

reportar_sucesso() {
	local id="$1" motivo="$2"
	registrar "$motivo"
	registrar "OCID: $id"

	local vnic_id ip=""
	vnic_id="$(
		timeout 60 "$OCI" compute instance list-vnics --instance-id "$id" \
			--query 'data[0].id' --raw-output 2>/dev/null 9>&-
	)"
	ip="$(
		timeout 60 "$OCI" compute instance list-vnics --instance-id "$id" \
			--query 'data[0]."public-ip"' --raw-output 2>/dev/null 9>&-
	)"
	[[ "$ip" == "null" ]] && ip=""

	# `--assign-public-ip true` na criação dá um IP EFÊMERO — ele muda se a
	# instância for parada e religada, o que quebraria o DNS silenciosamente.
	# Promove para reservado agora, no primeiro (e único) momento em que isso
	# importa. Best-effort: se falhar, a instância continua criada e utilizável
	# — só fica marcado no log para fazer manualmente no console
	# (Networking → Reserved Public IPs → Create, atribuir à VNIC).
	if [[ -n "$vnic_id" && "$vnic_id" != "null" ]]; then
		local private_ip_id
		private_ip_id="$(
			timeout 60 "$OCI" network private-ip list --vnic-id "$vnic_id" \
				--query 'data[0].id' --raw-output 2>/dev/null 9>&-
		)"
		if [[ -n "$private_ip_id" && "$private_ip_id" != "null" ]]; then
			local reservado
			reservado="$(
				timeout 60 "$OCI" network public-ip create \
					--compartment-id "$OCI_COMPARTMENT_ID" \
					--lifetime RESERVED \
					--private-ip-id "$private_ip_id" \
					--query 'data."ip-address"' --raw-output 2>/dev/null 9>&-
			)"
			if [[ -n "$reservado" && "$reservado" != "null" ]]; then
				registrar "IP promovido a reservado: $reservado (o efêmero anterior foi liberado automaticamente)"
				ip="$reservado"
			else
				registrar "AVISO: não consegui reservar o IP automaticamente — o IP atual ($ip) é EFÊMERO e muda se a instância parar. Reserve manualmente: console → Networking → Reserved Public IPs → Create, atribua à VNIC da instância."
			fi
		fi
	fi

	registrar "IP público: ${ip:-<consulte no console>}"

	avisar "OCI: instância criada" "IP ${ip:-?}"
	echo
	echo "======================================================================"
	echo "  Próximo passo:"
	echo "      ssh matheus@${ip:-SEU_IP} 'cloud-init status --wait'"
	echo
	echo "  Se o cloud-init falhar, a rota manual:"
	echo "      scp scripts/provisionar.sh ubuntu@${ip:-SEU_IP}:~"
	echo "      ssh ubuntu@${ip:-SEU_IP} 'sudo bash ~/provisionar.sh'"
	echo "======================================================================"
	exit 0
}

# Verificação defensiva de instância órfã: se uma execução anterior morreu
# entre criar a instância e detectar isso (kill, crash, o próprio bug do
# --wait-for-state acima numa versão antiga deste script), essa instância
# continua existindo mesmo sem aparecer no log como "INSTÂNCIA CRIADA".
#
# Retorno: 0 = achou (OCID no stdout), 1 = confirmado que NÃO existe,
# 2 = não consegui confirmar (timeout/erro da API) — o chamador deve tratar
# isso como "não sei" e pular o ciclo, nunca como "não existe": um 2 tratado
# como 1 é exatamente o cenário que cria uma instância duplicada.
verificar_existente() {
	local saida ret id
	saida="$(
		timeout 60 "$OCI" compute instance list \
			--compartment-id "$OCI_COMPARTMENT_ID" \
			--display-name "$NOME" \
			--query 'data[?"lifecycle-state"!=`TERMINATED`] | [0]' \
			--output json 2>/dev/null 9>&-
	)"
	ret=$?
	[[ $ret -eq 0 ]] || return 2
	[[ -n "$saida" && "$saida" != "null" ]] || return 1
	id="$(echo "$saida" | extrair_ocid)"
	[[ -n "$id" ]] || return 1
	echo "$id"
	return 0
}

registrar "início — intervalo ${INTERVALO}s, configs: ${CONFIGS[*]}"
registrar "log completo em $LOG"

CICLO=0
ERROS_SEGUIDOS=0
while :; do
	CICLO=$((CICLO + 1))
	if [[ "$TENTATIVAS" -gt 0 && "$CICLO" -gt "$TENTATIVAS" ]]; then
		registrar "desistindo após $TENTATIVAS ciclos sem capacidade"
		avisar "OCI: sem capacidade" "Desisti após $TENTATIVAS ciclos."
		exit 2
	fi

	SAIDA_VERIFICACAO="$(verificar_existente)"
	RET_VERIFICACAO=$?
	if [[ $RET_VERIFICACAO -eq 0 ]]; then
		reportar_sucesso "$SAIDA_VERIFICACAO" "instância '$NOME' já existe na conta (verificação prévia) — não crio outra"
	elif [[ $RET_VERIFICACAO -eq 2 ]]; then
		registrar "AVISO: não consegui confirmar se já existe instância (timeout/erro na verificação) — pulando ciclo $CICLO por segurança, para não arriscar criar uma duplicata"
		registrar "aguardando ${INTERVALO}s"
		sleep "$INTERVALO" 9>&-
		continue
	fi

	for cfg in "${CONFIGS[@]}"; do
		read -r OCPUS MEM <<<"$cfg"

		# Sonda barata (endpoint separado do launch) antes de gastar uma
		# tentativa real. Só pula o launch se a resposta for INEQUÍVOCA — uma
		# sonda vazia (timeout/erro) é tratada como "não sei" e o launch
		# acontece do mesmo jeito. A cada FORCAR_A_CADA ciclos, tenta mesmo
		# com a sonda dizendo que não há capacidade, como rede de segurança
		# contra o relatório estar desatualizado.
		STATUS_SONDA="$(sondar_capacidade "$OCPUS" "$MEM")"
		if [[ "$STATUS_SONDA" == "OUT_OF_HOST_CAPACITY" && $((CICLO % FORCAR_A_CADA)) -ne 0 ]]; then
			registrar "sem capacidade (sonda) para ${OCPUS}/${MEM}"
			continue
		fi

		registrar "ciclo $CICLO — tentando ${OCPUS} OCPU / ${MEM} GB"

		SAIDA="$(
			"$OCI" compute instance launch \
				--availability-domain "$OCI_AVAILABILITY_DOMAIN" \
				--compartment-id "$OCI_COMPARTMENT_ID" \
				--display-name "$NOME" \
				--shape "VM.Standard.A1.Flex" \
				--shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEM}}" \
				--image-id "$OCI_IMAGE_ID" \
				--subnet-id "$OCI_SUBNET_ID" \
				--assign-public-ip true \
				--boot-volume-size-in-gbs "$DISCO_GB" \
				--ssh-authorized-keys-file "$CHAVE_PUB" \
				--user-data-file "$CLOUD_INIT" \
				--wait-for-state RUNNING \
				--wait-for-state TERMINATED \
				--max-wait-seconds 900 \
				--no-retry \
				2>&1 9>&-
		)"
		CODIGO=$?

		# O OCID é a fonte da verdade, não o código de saída: se ele aparece
		# na saída, a instância foi criada — mesmo que o polling do
		# --wait-for-state tenha falhado depois (CODIGO != 0 nesse caso).
		ID="$(echo "$SAIDA" | extrair_ocid)"
		if [[ -n "$ID" ]]; then
			# A Oracle pode aceitar o launch (dá OCID, PROVISIONING) e falhar
			# o placement logo depois (TERMINATING/TERMINATED). Sem checar o
			# estado agora, o script declararia sucesso e sairia com uma
			# instância morta na mão.
			ESTADO="$(estado_instancia "$ID")"
			if [[ "$ESTADO" == "TERMINATING" || "$ESTADO" == "TERMINATED" ]]; then
				registrar "instância $ID foi criada mas terminou sozinha (estado $ESTADO — Oracle aceitou e depois falhou o placement). Seguindo o loop."
			elif [[ $CODIGO -eq 0 ]]; then
				reportar_sucesso "$ID" "INSTÂNCIA CRIADA com ${OCPUS} OCPU / ${MEM} GB"
			else
				reportar_sucesso "$ID" "INSTÂNCIA CRIADA com ${OCPUS} OCPU / ${MEM} GB (o polling --wait-for-state falhou depois, código $CODIGO — a instância existe mesmo assim)"
			fi
		fi

		if echo "$SAIDA" | grep -qiE 'out of (host )?capacity'; then
			registrar "sem capacidade para ${OCPUS}/${MEM}"
			ERROS_SEGUIDOS=0
		elif echo "$SAIDA" | grep -qiE 'too many requests'; then
			registrar "limite de requisições (429) — pausando 60s extra além do intervalo normal"
			sleep 60 9>&-
		elif echo "$SAIDA" | grep -qE "$FATAIS"; then
			registrar "ERRO PERMANENTE — abortando:"
			echo "$SAIDA" | tee -a "$LOG" >&2
			avisar "OCI: erro permanente" "Credencial, permissão ou cota. Veja o log."
			exit 1
		else
			# Transitório: timeout, DNS, 5xx, rede que sumiu na suspensão.
			ERROS_SEGUIDOS=$((ERROS_SEGUIDOS + 1))
			DETALHE="$(echo "$SAIDA" | grep -m1 -oE '"message"[^,]*' | cut -c1-100)"
			registrar "erro transitório ${ERROS_SEGUIDOS}/${MAX_ERROS_SEGUIDOS}: ${DETALHE:-sem detalhe}"
			if [[ $ERROS_SEGUIDOS -ge $MAX_ERROS_SEGUIDOS ]]; then
				registrar "ERRO: $MAX_ERROS_SEGUIDOS falhas transitórias seguidas — algo está errado de verdade"
				echo "$SAIDA" | tee -a "$LOG" >&2
				avisar "OCI: loop parado" "Muitos erros seguidos. Veja o log."
				exit 1
			fi
		fi
	done

	registrar "aguardando ${INTERVALO}s"
	sleep "$INTERVALO" 9>&-
done
