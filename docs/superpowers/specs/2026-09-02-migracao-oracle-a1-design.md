# Servidor pessoal no Oracle Cloud Always Free (Ampere A1)

Data: 2026-09-02
Estado: aprovado, pendente de plano de implementação

## 1. Contexto

Em 07/08/2026 o servidor pessoal foi desenhado para um **Hetzner CAX11**
(ARM64, 2 vCPU, 4 GB, ~R$ 25/mês). O repositório `servidor-pessoal` foi escrito
por inteiro — cloud-init, compose da infra, Caddyfile, scripts de backup e
restore, runbook — mas **nunca foi executado**: nenhum servidor chegou a ser
provisionado.

Naquela decisão o Oracle Cloud Always Free foi explicitamente **rejeitado** pelo
risco de reclaim e suspensão. Esse risco se materializou desde então:

- **15/06/2026** — a Oracle reduziu o Always Free de 4 OCPU/24 GB para
  2 OCPU/12 GB, sem anúncio público, apenas editando a documentação.
- **18/08/2026** — instâncias acima do novo limite foram terminadas.

A decisão foi revista com esses fatos na mesa: o alvo passa a ser o Oracle A1,
com custo zero, e o risco é aceito conscientemente e mitigado por backup
externo ao provedor.

## 2. Alvo

| Item | Valor |
|---|---|
| Provedor | Oracle Cloud Infrastructure, Always Free |
| Shape | `VM.Standard.A1.Flex` — 2 OCPU ARM, 12 GB RAM |
| Home region | `sa-saopaulo-1` (**irreversível** após o cadastro) |
| Imagem | Canonical Ubuntu 24.04 LTS, aarch64 |
| Boot volume | 100 GB (do total de 200 GB do Always Free) |
| IP público | reservado, não efêmero |
| Egress | 10 TB/mês |
| Custo | R$ 0 |

`sa-saopaulo-1` foi escolhida sobre `us-ashburn-1` por latência (~10–20 ms
contra ~130 ms). O custo de estar errado é a criação falhar com
`Out of host capacity` e ser preciso retentar, não perder o servidor.

## 3. O que não muda

A arquitetura decidida em agosto permanece integralmente válida, e o A1 é
ARM64 como o CAX11 — as imagens dos containers são as mesmas.

- **Um único Postgres**, um database por projeto (não um container por projeto).
- **Caddy** como proxy reverso e TLS automático (não Traefik).
- **Só o Caddy publica portas.** Todo o resto conversa pelas redes `edge` e `data`.
- **Repo é molde, servidor é o estado.** `/opt/stacks` fica fora do git.
- **Backup restic para Cloudflare R2**, fora do provedor. Agora ainda mais
  importante: é a única defesa contra a Oracle levar a instância.
- `infra/compose.yml`, `infra/Caddyfile`, `templates/`, `scripts/backup.sh`,
  `scripts/restore.sh`, `scripts/restore-stacks.sh`, `systemd/` — inalterados
  em estrutura.

## 4. O que muda

### 4.1 Firewall — duas camadas

**Fora da VM (a defesa que conta):** Security List do VCN com ingress
`22/tcp`, `80/tcp`, `443/tcp` e `443/udp` de `0.0.0.0/0` e `::/0`.
Substitui o Hetzner Cloud Firewall com a mesma propriedade essencial: roda
fora da VM, o Docker escreve iptables por dentro e não a alcança. A regra de
ouro "só o Caddy usa `ports:`" continua sendo o que impede vazamento.

**Dentro da VM:** a imagem Ubuntu do OCI traz `iptables-persistent` com REJECT
para tudo exceto 22, e a Oracle desabilita o `ufw` para evitar conflito com o
tooling dela. **Decisão: purgar o `iptables-persistent` e usar apenas o `ufw`**,
como no cloud-init já escrito. Uma camada, um modelo mental, o runbook continua
valendo. A alternativa rejeitada — manter as regras da Oracle e injetar 80/443
via `iptables-legacy` — obrigaria a lembrar de duas ferramentas para sempre.

**Ordem obrigatória** no `runcmd`: purgar → flush → política ACCEPT →
`ufw --force enable`. Isso abre uma janela de segundos com a VM sem firewall
local. É aceitável **somente porque a Security List já está fechada por fora**.
Consequência de runbook: **a Security List é criada antes da instância.**

### 4.2 Acesso de emergência

No OCI não existe console web equivalente ao da Hetzner — só o Console
Connection serial. Uma chave SSH errada no cloud-init custa muito mais caro.

Mitigação: colar a chave pública **também** no campo "Add SSH keys" do console
de criação. Ela é injetada no usuário `ubuntu`, que passa a existir ao lado do
`matheus` como porta de emergência. O hardening (`PermitRootLogin no`,
`PasswordAuthentication no`, `AuthenticationMethods publickey`) permanece
inalterado e vale para ambos.

### 4.3 Dimensionamento do Postgres

Calibrado para 4 GB, agora recalibrado para 12 GB em `infra/compose.yml`:

| Parâmetro | Antes (4 GB) | Depois (12 GB) |
|---|---|---|
| `shared_buffers` | 256MB | 3GB |
| `effective_cache_size` | 1GB | 8GB |
| `work_mem` | 8MB | 16MB |
| `maintenance_work_mem` | 64MB | 512MB |
| `max_connections` | 60 | 100 |

O teto de memória do template de projeto (512M para `app`, 256M para `worker`)
deixa de ser apertado; permanece como default sensato, agora com folga real.
O swap de 2 GB e `vm.swappiness=10` são mantidos.

### 4.4 Disco

O boot volume de 100 GB não é enxergado pelo filesystem automaticamente.
Passo obrigatório após o primeiro boot:

    sudo /usr/libexec/oci-growfs -y

Diferente da Hetzner, aqui não há a armadilha do "aumento de disco
irreversível" — mas o Always Free tem teto de 200 GB de block storage no
total, e os 100 GB restantes ficam de folga deliberada.

### 4.5 Porta 25 bloqueada

A Oracle bloqueia SMTP de saída. Qualquer projeto que envie e-mail precisa
usar API (Resend, Postmark, SES) em vez de SMTP direto. Vale como nota no
runbook, não muda arquitetura.

## 5. Política de idle reclaim

A documentação da Oracle define instância ociosa como, **durante 7 dias**:

    CPU p95 < 20%  E  rede < 20%  E  memória < 20%   (memória só em shapes A1)

São três condições em **AND**. Duas são inalcançáveis por um servidor pessoal
no sentido do perigo:

- **CPU**: ficará abaixo de 20%, sim.
- **Rede**: a A1 tem ~1 Gbps por OCPU. 20% seriam ~400 Mbps sustentados por
  7 dias. Nunca será atingido.
- **Memória**: 20% de 12 GB = **2,4 GB**. Esta é a única alavanca realista.

Com `shared_buffers=3GB` mais Uptime Kuma e as apps, o consumo *deveria* ficar
acima de 2,4 GB. **Isto não é uma garantia.** O Postgres só ocupa as páginas de
`shared_buffers` conforme as toca, e não está estabelecido como o
`oracle-cloud-agent` computa "memory utilization" — se inclui cache de página
ou não.

**Decisão: medir, não presumir.** Entra no runbook um passo explícito:

> Após 7 dias no ar, consultar a métrica `MemoryUtilization` no OCI Monitoring.
> Acima de 20%: nada a fazer. Abaixo: decidir a mitigação com o número na mão.

Nenhuma mitigação preventiva (carga sintética, `stress` em cron) será
implementada. São gambiarras frágeis para um problema que talvez não exista.

O `oracle-cloud-agent` **não** deve ser removido: é ele que publica as métricas.

## 6. Riscos e mitigações

| Risco | Probabilidade | Mitigação |
|---|---|---|
| `Out of host capacity` para A1 em São Paulo | alta | Retentar. Se não sair em ~2 dias, reavaliar contra o CAX11 pago em Ashburn. |
| Oracle cortar o Always Free de novo | demonstrada, 2× em 2026 | restic no R2 + `restore-stacks.sh` + `restore.sh` reconstroem em qualquer provedor. |
| Instância reclaimed por ociosidade | baixa, a medir | Seção 5. Backup como rede final. |
| Suspensão arbitrária da conta | baixa | Idem. O backup vive fora do provedor por decisão de projeto. |
| Se trancar fora por chave errada | média (pior que na Hetzner) | Chave também no campo do console → usuário `ubuntu`. Console Connection serial como último recurso. |
| Perder a `RESTIC_PASSWORD` | catastrófica | Gerenciador de senhas, fora do servidor, **antes** do primeiro backup. |
| IP efêmero mudar ao parar a instância | média | Reservar o IP público no console. |

## 7. Escopo da mudança no repositório

Decisão: o repositório passa a documentar **apenas o OCI**. O conteúdo
Hetzner-específico (Cloud Firewall, Rescale CAX11→CAX21, armadilha do disco
irreversível, custo em euros) é removido.

**Exceção deliberada:** a seção "Reconstruir do zero" permanece, reescrita em
forma **neutra de provedor**. Ela não é sobre a Hetzner — é a garantia de
recuperação contra exatamente o risco que o Oracle introduz. Removê-la junto
com o provedor antigo apagaria a mitigação principal.

Arquivos afetados:

| Arquivo | Mudança |
|---|---|
| `cloud-init.yaml` | cabeçalho, hostname, purga do `iptables-persistent`, `oci-growfs` |
| `infra/compose.yml` | parâmetros do Postgres para 12 GB |
| `README.md` | runbook reescrito para OCI; passos de Security List, região, growfs, métrica de idle |
| `scripts/*` | nenhuma mudança funcional esperada |
| `templates/*` | nenhuma mudança |
| `systemd/*` | nenhuma mudança |

## 8. Critérios de sucesso

1. `https://<dominio>` responde com certificado válido do Let's Encrypt.
2. `https://status.<dominio>` abre o Uptime Kuma, com login criado na hora.
3. `ssh root@<ip>` falha; `ssh matheus@<ip>` funciona por chave.
4. `sudo ufw status` mostra 22, 80, 443/tcp e 443/udp; `iptables-persistent`
   ausente do sistema.
5. `docker network ls` mostra `edge` e `data`.
6. `df -h /` mostra os 100 GB (prova de que o `oci-growfs` rodou).
7. `backup.sh` executa manualmente, cria o repositório restic e pinga o Kuma.
8. `restore.sh` e `restore-stacks.sh` são testados com o servidor ainda vazio.
9. `novo-projeto.sh` cria um projeto de ponta a ponta e ele responde em
   `https://<projeto>.<dominio>`.
10. Após 7 dias: `MemoryUtilization` consultada no OCI Monitoring e registrada.
