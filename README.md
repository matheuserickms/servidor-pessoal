# Servidor pessoal — Hetzner Cloud (CX23)

Runbook do zero até o primeiro projeto no ar. Siga na ordem; cada passo
assume o anterior pronto.

> Existe um caminho alternativo, de custo zero, na Oracle Cloud Always Free —
> mas em 13 dias de tentativas automáticas (set/2026) a Oracle nunca liberou
> capacidade em São Paulo. Está documentado no [apêndice](#apêndice-oracle-cloud-always-free-opcional)
> como loteria opcional, não como plano.

## O que este setup é

Um VPS de 4 GB rodando Docker, com Caddy fazendo proxy reverso e TLS
automático, um Postgres compartilhado (um database por projeto) e backup
diário criptografado para fora do provedor.

```
        internet
           │
    Hetzner Cloud Firewall        ← 22, 2222, 80, 443 e nada mais
           │
    ┌──────┴──────────────────────────────────┐
    │  CX23 · Ubuntu 24.04 · x86_64           │
    │                                         │
    │   Caddy ──rede "edge"──► app-a, app-b   │
    │     │                       │           │
    │     └── uptime-kuma         │           │
    │                        rede "data"      │
    │                             │           │
    │                          Postgres ◄── worker/bot
    └─────────────────────────────────────────┘
                     │ diário, criptografado
                     ▼
             Cloudflare R2 / Backblaze B2
```

**Custo mensal:** US$ 7,09 (CX23 6,49 + IPv4 0,60), sem IVA, cobrado por
hora — ~R$ 40 com IOF. Domínio à parte, ~R$ 40–90/ano.

## Arquivos

| Arquivo | Vai para | O que faz |
|---|---|---|
| `cloud-init.yaml` | campo "Cloud config" na criação do servidor | provisiona a máquina inteira no primeiro boot (serve para Hetzner e OCI) |
| `scripts/provisionar.sh` | roda por SSH no servidor, sob demanda | equivalente manual do cloud-init, para quando ele não roda |
| `infra/compose.yml` | `/opt/stacks/_infra/` | Caddy + Postgres + Uptime Kuma |
| `infra/Caddyfile` | `/opt/stacks/_infra/` | roteamento e TLS |
| `infra/.env.example` | `/opt/stacks/_infra/.env` | domínio, e-mail ACME, senha do banco |
| `templates/projeto-exemplo/` | modelo | base de cada projeto novo |
| `scripts/deploy-infra.sh` | roda no notebook | envia o molde sem tocar no estado vivo |
| `scripts/novo-projeto.sh` | `~/servidor/scripts/` | cria database, stack e rota de uma vez |
| `scripts/backup.sh` | `/usr/local/bin/` | dump + envio para o bucket |
| `scripts/restore.sh` | `/usr/local/bin/` | restaura os **dados** de um snapshot |
| `scripts/restore-stacks.sh` | `/usr/local/bin/` | restaura a **configuração** de um snapshot |
| `scripts/backup.env.example` | `/etc/backup.env` | credenciais do bucket e chave de cripto |
| `systemd/backup.{service,timer}` | `/etc/systemd/system/` | agenda o backup |
| `scripts/criar-instancia.sh`, `scripts/oci.env` | só no notebook | loop da Oracle (apêndice) |

---

## 1. Chave SSH

No seu notebook, se ainda não tiver:

```bash
ssh-keygen -t ed25519 -C "matheus@notebook"
cat ~/.ssh/id_ed25519.pub
```

Essa chave vai para **dois** lugares (passo 4): o `cloud-init.yaml`
(usuário `matheus`, o de uso normal) e o campo "SSH keys" do console da
Hetzner (usuário `root`, que o cloud-init desabilita em seguida — mas fica
disponível pelo console VNC da Hetzner em emergência). **O setup desabilita
login por senha** — se a chave estiver errada, você fica de fora.

## 2. Domínio

Registre em qualquer registrador. Duas opções sensatas:

- **`.com.br`** no [registro.br](https://registro.br) — ~R$ 40/ano, exige CPF
  (ou CNPJ, o que mantém seus dados fora do WHOIS público)
- **`.dev`** no Cloudflare Registrar — ~R$ 90/ano, vendido a preço de custo, e
  o TLD inteiro está no HSTS preload (HTTPS forçado no navegador de graça)

## 3. DNS na Cloudflare

Crie a conta, **Adicionar um site → Conectar um domínio**, plano Free. A
Cloudflare varre o DNS atual e importa o que achar (no registro.br, um
domínio novo costuma vir com `MX .` + SPF `-all` + DMARC — registros
anti-spoofing que dizem "não envio e-mail"; mantenha). Depois adicione,
todos com proxy **desligado** (nuvem cinza, "Somente DNS"):

| Tipo | Nome | Conteúdo |
|---|---|---|
| A | `@` | IPv4 do servidor |
| A | `*` | IPv4 do servidor |
| AAAA | `@` | IPv6 do servidor (`…::1` do /64 que a Hetzner dá) |
| AAAA | `*` | IPv6 do servidor |

O wildcard faz todo subdomínio futuro funcionar sem mexer em DNS de novo.
Os IPs você só tem depois do passo 4 — crie a zona agora, volte para os
registros depois.

Ao final a Cloudflare entrega **dois nameservers** (`xxx.ns.cloudflare.com`).
No registro.br: **Domínios → seu domínio → DNS → Alterar servidores DNS**,
troque os `a/b.auto.dns.br` por eles. Armadilha: se você mexeu no DNS do
domínio há pouco (ou ele é novo), o registro.br trava a delegação por ~2h
("servidores DNS em transição"). Não tem atalho, é esperar.

**Mantenha o proxy desligado no início.** Com a nuvem laranja ligada, o
Cloudflare termina o TLS por você e o Caddy passa a ver todo tráfego vindo do
IP deles — o que quebra rate limiting por IP e dificulta diagnosticar erro de
certificado. Ligue depois, se quiser esconder o IP de origem.

## 4. Criar o servidor

[console.hetzner.com](https://console.hetzner.com) → projeto → **Create
resource → Server**. Conta nova passa por verificação manual (documento ou
pré-pagamento), de horas a um dia útil — não deixe para a véspera.

### 4.1 Firewall primeiro

**Firewalls → Create Firewall**, regras de entrada (o console já traz 22/tcp
e ICMP; adicione as outras quatro). Tudo o mais é bloqueado:

| Protocolo | Porta | Origem |
|---|---|---|
| TCP | 22 | Any IPv4, Any IPv6 |
| TCP | 2222 | Any IPv4, Any IPv6 |
| TCP | 80 | Any IPv4, Any IPv6 |
| TCP | 443 | Any IPv4, Any IPv6 |
| UDP | 443 | Any IPv4, Any IPv6 |
| ICMP | — | Any IPv4, Any IPv6 |

A regra UDP é o HTTP/3 do Caddy — fácil de esquecer, e o sintoma (HTTP/2
funciona, HTTP/3 falha em silêncio) não aponta óbvio para "faltou uma regra
de firewall".

**O firewall precisa existir antes do servidor.** O `cloud-init.yaml` sobe o
`ufw` só depois do `apt upgrade`; até lá, é o Cloud Firewall — fora da VM —
que protege.

> Com IP fixo, restringir a 22 à sua origem seria melhor. Com IP residencial
> dinâmico, isso te tranca do lado de fora no dia que o IP mudar — o
> `fail2ban` cobre o risco de força bruta (em 1h de vida o `srv01` já tinha
> 120 tentativas e 1 IP banido).

### 4.2 O servidor

- **Location:** Nuremberg (ou Falkenstein/Helsinki — mesmo preço, ~150 ms do
  Brasil). Ashburn/Hillsboro (EUA) **não** têm a categoria barata: o mais
  barato lá é CPX11 com 2 GB por US$ 20 — 3× o preço por metade da RAM.
- **Image:** Ubuntu **24.04** (o default do console é o LTS mais novo; o
  cloud-init foi validado em 24.04)
- **Type:** Shared → **Cost-Optimized** → x86 → **CX23** (2 vCPU, 4 GB,
  40 GB, 20 TB). O CAX11 ARM (aba Arm64) tem as mesmas specs por US$ 0,50 a
  mais e costuma aparecer "Not available" nas três locations; se estiver
  disponível, serve igual — o cloud-init é agnóstico de arquitetura.
- **Networking:** IPv4 + IPv6 (IPv4 custa US$ 0,60/mês; sem ele metade da
  internet não te alcança)
- **SSH keys:** Add SSH key → cole sua `id_ed25519.pub`
- **Firewalls:** marque o firewall do 4.1
- **Cloud config:** cole o `cloud-init.yaml` **inteiro**, do `#cloud-config`
  ao `final_message`
- **Name:** `srv01`

**Create & Buy now.** O IP aparece na lista de servidores em segundos; o
IPv6 vem como um `/64` — o endereço do servidor é o `::1` dele.

Volte ao passo 3 e crie os registros DNS.

## 5. Primeiro acesso

O cloud-init leva ~1–3 minutos (o `srv01` levou 72 s). Depois:

```bash
ssh matheus@SEU_IP

# Esperar o provisionamento terminar de verdade
cloud-init status --wait

# O que o runcmd (com `set -x`) realmente fez fica aqui, não no journalctl:
sudo tail -100 /var/log/cloud-init-output.log
```

Verificações que valem os 30 segundos:

```bash
docker run --rm hello-world          # docker funciona sem sudo
docker network ls | grep -E 'edge|data'
free -h                              # deve mostrar 2 Gi de swap
sudo ufw status                      # 22, 2222, 80, 443/tcp, 443/udp
sudo fail2ban-client status sshd     # jail ativo (não só o serviço)
ssh root@SEU_IP                      # DEVE falhar — se entrar, algo deu errado
```

**Se o SSH dá timeout mas `ping` responde**, antes de culpar o servidor:
`nc -zv github.com 22`. Redes corporativas e de convidados costumam
bloquear saída na porta 22 para qualquer destino — o sintoma é idêntico ao
de um firewall no servidor. Por isso o sshd também escuta na **2222**
(`ssh -p 2222 matheus@SEU_IP`); a 22 continua para o dia a dia. Aconteceu
no primeiro acesso do `srv01` (Wi-Fi `#GSI`), antes de a 2222 existir — a
saída foi hotspot do celular.

**Se `cloud-init status --wait` nunca terminar ou `ssh matheus@` falhar**, a
rota manual é o `provisionar.sh` — ele faz exatamente o que o cloud-init
faria, mas por SSH e de forma visível. Entre como `root` pelo console VNC da
Hetzner (Actions → Console) ou, se o sshd ainda aceitar root, por SSH:

```bash
scp scripts/provisionar.sh root@SEU_IP:~
ssh root@SEU_IP 'bash ~/provisionar.sh'
# NÃO feche esta sessão ainda — em outro terminal, teste antes:
ssh matheus@SEU_IP
```

Opcional, mas ajuda a ler log: `sudo timedatectl set-timezone America/Sao_Paulo`.
Se fizer isso, lembre que o `backup.timer` passa a rodar 03:10 no horário de
Brasília em vez de UTC.

## 6. Subir a infraestrutura

O `infra/compose.yml` já vem calibrado para 4 GB compartilhados (Postgres com
`shared_buffers=256MB`, `effective_cache_size=1GB`, 60 conexões — de
propósito bem abaixo da regra dos 25%, porque Caddy, Kuma e os projetos
dividem a mesma RAM).

Do seu notebook, de dentro deste repo:

```bash
./scripts/deploy-infra.sh matheus@SEU_IP
```

Ele cria os diretórios, envia `compose.yml`, `Caddyfile`, `.env.example`,
os scripts e os templates — e para na primeira execução avisando que falta o
`.env`. No servidor:

```bash
cd /opt/stacks/_infra
cp .env.example .env && chmod 600 .env

openssl rand -base64 32     # senha do banco, cole no .env
nano .env                   # DOMINIO, ACME_EMAIL, POSTGRES_PASSWORD

docker compose up -d
docker compose ps           # os três "healthy" em ~10 s
```

Da próxima vez que você mexer no `compose.yml` ou no `Caddyfile`, é só rodar o
`deploy-infra.sh` de novo — ele pergunta se aplica na hora.

Confira o TLS. O primeiro certificado leva alguns segundos:

```bash
docker compose logs -f caddy    # procure por "certificate obtained successfully"
curl -I https://SEU_DOMINIO
```

Se o DNS ainda não propagou, o Caddy tenta e falha em loop — sem problema, ele
consegue sozinho quando o registro resolver. Só não fique repetindo `restart`:
o Let's Encrypt tem limite de 5 falhas por hora por domínio, e ao estourar
você fica travado até a hora seguinte.

Acesse `https://status.SEU_DOMINIO` e crie o login do Uptime Kuma **na hora** —
até você criar, a tela de cadastro fica aberta para quem chegar primeiro.

## 7. Backup

Crie o bucket (Cloudflare R2 ou Backblaze B2, ambos com 10 GB grátis — o R2
exige cartão cadastrado mesmo dentro do free tier) e um token de
leitura/escrita. No servidor:

```bash
sudo cp ~/servidor/scripts/backup.sh ~/servidor/scripts/restore*.sh /usr/local/bin/
sudo chmod 700 /usr/local/bin/backup.sh /usr/local/bin/restore*.sh

sudo cp ~/servidor/scripts/backup.env.example /etc/backup.env
sudo chmod 600 /etc/backup.env
sudo nano /etc/backup.env          # credenciais + RESTIC_PASSWORD

sudo cp ~/servidor/systemd/backup.service ~/servidor/systemd/backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer

# Primeira execução manual: inicializa o repositório restic
sudo /usr/local/bin/backup.sh
```

**Guarde a `RESTIC_PASSWORD` num gerenciador de senhas fora do servidor.**
Sem ela o backup é um bloco de ruído — nem você, nem o provedor de storage,
nem ninguém consegue abrir.

```bash
systemctl list-timers backup.timer    # próximo disparo
journalctl -u backup.service -n 50    # última execução
```

## 8. Testar o restore

Faça isso agora, com o servidor vazio, quando errar não custa nada:

```bash
sudo /usr/local/bin/restore.sh
```

Ele pede o hostname digitado como confirmação, valida a integridade do gzip
antes de tocar no banco e aplica o dump. Se funcionar com o banco vazio, vai
funcionar no dia ruim.

Teste também o outro lado — a configuração:

```bash
sudo /usr/local/bin/restore-stacks.sh        # baixa para staging, não sobrescreve
sudo ls -la /var/backups/restore-stacks/opt/stacks/
```

São dois scripts porque são duas metades: `restore.sh` traz os **dados**,
`restore-stacks.sh` traz a **configuração** (composes, rotas do Caddy e os
`.env` com as senhas dos databases). Restaurar só um dos dois não devolve um
servidor funcionando.

Uma vez por mês, verificação profunda (lê os dados de fato, não só os
metadados):

```bash
source /etc/backup.env && sudo -E restic check --read-data-subset=10%
```

## 9. Primeiro projeto

Os scripts e templates já foram para o servidor no passo 6. Então:

```bash
ssh matheus@SEU_IP
~/servidor/scripts/novo-projeto.sh meu-blog
```

O script cria o database e o role dedicados, gera `/opt/stacks/meu-blog/` a
partir do template com a `DATABASE_URL` já preenchida, e registra
`/opt/stacks/_infra/sites/meu-blog.caddy`. Falta você ajustar a imagem e a
porta interna no `compose.yml`, subir e recarregar o proxy:

```bash
cd /opt/stacks/meu-blog
nano compose.yml
docker compose up -d

cd /opt/stacks/_infra
docker compose exec caddy caddy reload -c /etc/caddy/Caddyfile
```

Pronto: `https://meu-blog.SEU_DOMINIO`.

**Domínio próprio para um projeto** (vários domínios no mesmo servidor):

```bash
~/servidor/scripts/novo-projeto.sh loja lojadamaria.com.br
```

Gera a rota como `lojadamaria.com.br, www.lojadamaria.com.br` em vez de
subdomínio. O DNS desse domínio é por sua conta: zona nova na Cloudflare
(passo 3, mesmos `A/AAAA` de `@` e `*` apontando para este servidor) e NS
trocados no registrador. O Caddy pede o certificado na primeira visita.

---

## Operação

```bash
# Ver o que está consumindo RAM — o número que mais importa com 4 GB
docker stats --no-stream

# Espaço em disco (40 GB somem rápido com imagens órfãs)
df -h /  &&  docker system df

# Limpeza de imagens órfãs
docker image prune -a

# Atualizar um projeto
cd /opt/stacks/<projeto> && docker compose pull && docker compose up -d

# psql do seu notebook, sem expor o banco na internet
ssh -L 5432:localhost:5432 matheus@SEU_IP \
    'docker compose -f /opt/stacks/_infra/compose.yml exec postgres psql -U postgres'
```

Sinais de que os 4 GB acabaram: swap em uso constante acima de ~500 MB,
containers mortos por OOM (`dmesg | grep -i oom`), somatório dos limites de
memória dos projetos passando de ~2,5 GB. A saída é o **Rescale** no console
da Hetzner (CX33: 4 vCPU/8 GB, US$ 9,99) — exige desligar o servidor por um
minuto, e disco maior é irreversível (marque "só CPU/RAM" para poder voltar).
Depois, dobre `shared_buffers`/`effective_cache_size` no `compose.yml` e
rode `deploy-infra.sh`.

## Modelo: o repo é molde, o servidor é o estado

Este repositório **não** é a fonte da verdade do que está rodando. Ele é o
molde: o que você precisa para construir um servidor, não o retrato do
servidor construído.

| | Onde vive | Como se recupera |
|---|---|---|
| cloud-init, infra base, templates, scripts | este repo (git) | `git clone` + passo 4 + `deploy-infra.sh` |
| `/opt/stacks/<projeto>/` e os `.env` | só no servidor | `restore-stacks.sh` |
| databases | só no Postgres | `restore.sh` |

A consequência prática: **`/opt/stacks` fica fora do git de propósito**, e a
única coisa que o protege é o backup do restic. Se o `backup.timer` parar de
rodar e você não notar, você perde os `.env` com as senhas dos databases — que
são geradas aleatoriamente pelo `novo-projeto.sh` e não existem em nenhum
outro lugar.

Por isso, duas rotinas que não são opcionais neste modelo:

1. Um monitor no Uptime Kuma do tipo **Push**. O `backup.sh` já pinga ao
   terminar — basta criar o monitor, copiar a URL e pôr em `/etc/backup.env`:
   ```bash
   export BACKUP_PING_URL="https://status.SEU_DOMINIO/api/push/XXXXX"
   ```
   O ping acontece só no fim, depois de dump, upload e `restic check`. Se
   qualquer etapa falhar, o script aborta antes e o Kuma deixa de receber
   sinal — que é justamente o alarme. Enquanto a variável estiver vazia, o
   script avisa no log que nada vai te alertar se o backup parar.
2. `restic snapshots` de vez em quando, só para ver que a data do último
   snapshot é de ontem e não de três meses atrás.

Quando você editar `compose.yml`, `Caddyfile`, um template ou um script:
commite aqui, rode `./scripts/deploy-infra.sh`, pronto. Quando você criar um
projeto: isso acontece no servidor e o repo não fica sabendo — é o esperado.

## Reconstruir do zero

Cenário: o servidor morreu, a conta foi suspensa, ou você quer migrar de
provedor. Com os três pedaços acima, a reconstrução é mecânica:

```bash
# 1. Servidor novo (passo 4 deste runbook, do zero)
# 2. Aponte o DNS para o IP novo (passo 3)

# 3. Do notebook, no repo:
./scripts/deploy-infra.sh matheus@IP_NOVO

# 4. No servidor novo — credenciais do bucket primeiro:
sudo cp ~/servidor/scripts/backup.env.example /etc/backup.env
sudo chmod 600 /etc/backup.env
sudo nano /etc/backup.env          # cole a RESTIC_PASSWORD do gerenciador de senhas
sudo cp ~/servidor/scripts/restore*.sh /usr/local/bin/ && sudo chmod 700 /usr/local/bin/restore*.sh

# 5. Configuração de volta (traz os .env com as senhas dos databases)
sudo /usr/local/bin/restore-stacks.sh --in-place

# 6. Infra de pé, depois os dados
cd /opt/stacks/_infra && docker compose up -d
sudo /usr/local/bin/restore.sh

# 7. Projetos de volta
for d in /opt/stacks/*/; do
  [ "$d" = /opt/stacks/_infra/ ] && continue
  (cd "$d" && docker compose up -d)
done
```

O passo 4 é o único que depende de algo que não está em lugar nenhum
automatizado: a `RESTIC_PASSWORD`. Sem ela, os passos 5 e 6 são impossíveis e
o backup inteiro vira ruído. **Guarde num gerenciador de senhas hoje.**

## Armadilhas conhecidas

**O Docker ignora o `ufw`.** Ele escreve regras de iptables por fora e uma
porta publicada com `ports:` fica exposta na internet mesmo com o `ufw` negando.
Por isso o Hetzner Cloud Firewall — que roda fora da VM e o Docker não
alcança — é a defesa que de fato conta. Regra do setup: **só o Caddy usa
`ports:`**. Todo o resto conversa pelas redes internas.

**Porta 25 (SMTP) de saída é bloqueada em conta nova da Hetzner** (e sempre
na Oracle). Qualquer projeto que envie e-mail deve usar API (Resend,
Postmark, SES) em vez de SMTP direto.

**Alias de rede é obrigatório em rede compartilhada.** Dois projetos com um
serviço chamado `app` na rede `edge` colidem no DNS e o Caddy passa a rotear
para o container errado, de forma intermitente. O template já define
`aliases: [PROJETO-app]`; não remova.

**Não apague o volume `caddy_data`.** Ali moram os certificados. Perder e
repedir tudo de uma vez pode bater no rate limit do Let's Encrypt (50
certificados por domínio registrado por semana).

**`docker compose down -v` apaga volumes.** No stack `_infra` isso significa o
banco inteiro. Use `down` sem `-v`.

**Rescale com disco é irreversível.** Aumentar só CPU/RAM pode voltar
atrás; aumentar o disco, não.

---

## Apêndice: Oracle Cloud Always Free (opcional)

Entre 02 e 14/09/2026 este repo tentou subir na Oracle (`VM.Standard.A1.Flex`,
2 OCPU/12 GB ARM, R$ 0) em `sa-saopaulo-1`. Resultado: **16 mil+ tentativas
sem capacidade**, e o `compute-capacity-report` da própria Oracle confirmando
pool zerado para todos os shapes free. A decisão de 13/09 foi subir a Hetzner
e deixar o loop rodando como loteria — se um dia sair, migrar é o
"Reconstruir do zero" acima apontado para o IP novo. O design completo da
tentativa está em `docs/superpowers/specs/2026-09-02-migracao-oracle-a1-design.md`.

O que fica no repo para isso:

- `scripts/criar-instancia.sh` — loop via OCI CLI (`~/.local/share/oci-cli-venv`,
  config em `~/.oci/`). Sonda `compute-capacity-report` antes de cada
  launch, `--no-retry`, trava `flock` dentro do repo, detecta sucesso pelo
  OCID (não pelo código de saída), promove o IP a reservado sozinho. Morre
  junto com a suspensão do notebook; religar:
  ```bash
  setsid nohup ./scripts/criar-instancia.sh >/dev/null 2>&1 & disown
  tail -f criar-instancia.log
  ```
- `scripts/oci.env` (ignorado pelo git) — os 4 OCIDs; modelo em `oci.env.example`.
- `cloud-init.yaml` — o mesmo arquivo; o script passa via `--user-data-file`.
  O bloco de growfs e a purga do `iptables-persistent` existem por causa da
  imagem da Oracle e são inofensivos na Hetzner.

Se sair, o que muda em relação ao runbook Hetzner: Security List do VCN faz o
papel do Cloud Firewall (**criada antes da instância**, mesmas 4 regras);
`compose.yml` do Postgres deve ser retunado para 12 GB (`shared_buffers=3GB`,
`effective_cache_size=8GB`, `work_mem=16MB`, `maintenance_work_mem=512MB`,
100 conexões) ou 6 GB (metade disso); vigiar o **idle reclaim** (7 dias com
CPU p95 <20% E rede <20% E memória <20% — checar `MemoryUtilization` no OCI
Monitoring, não remover o `oracle-cloud-agent`); teto de 200 GB de block
storage; e a home region é irreversível. O console web da Oracle concatena
em vez de substituir nos campos de cloud-init e chave SSH — por isso o
script existe.
