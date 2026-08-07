# Servidor pessoal — Hetzner CAX11

Runbook do zero até o primeiro projeto no ar. Siga na ordem; cada passo
assume o anterior pronto.

## O que este setup é

Um VPS ARM de 4 GB rodando Docker, com Caddy fazendo proxy reverso e TLS
automático, um Postgres compartilhado (um database por projeto) e backup
diário criptografado para fora do provedor.

```
        internet
           │
    Hetzner Cloud Firewall        ← 22, 80, 443 e nada mais
           │
    ┌──────┴──────────────────────────────────┐
    │  CAX11 · Ubuntu 24.04 · ARM64           │
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

**Custo mensal:** ~€6,49 (CAX11 + IPv4) ≈ R$ 43, mais IOF e spread do cartão.
Conte ~R$ 46. Domínio à parte, ~R$ 40–90/ano.

## Arquivos

| Arquivo | Vai para | O que faz |
|---|---|---|
| `cloud-init.yaml` | campo "Cloud config" na criação | provisiona a máquina inteira no primeiro boot |
| `infra/compose.yml` | `/opt/stacks/_infra/` | Caddy + Postgres + Uptime Kuma |
| `infra/Caddyfile` | `/opt/stacks/_infra/` | roteamento e TLS |
| `infra/.env.example` | `/opt/stacks/_infra/.env` | domínio, e-mail ACME, senha do banco |
| `templates/projeto-exemplo/` | modelo | base de cada projeto novo |
| `scripts/novo-projeto.sh` | `~/bin/` | cria database, stack e rota de uma vez |
| `scripts/backup.sh` | `/usr/local/bin/` | dump + envio para o bucket |
| `scripts/restore.sh` | `/usr/local/bin/` | restaura de um snapshot |
| `scripts/backup.env.example` | `/etc/backup.env` | credenciais do bucket e chave de cripto |
| `systemd/backup.{service,timer}` | `/etc/systemd/system/` | agenda o backup |

---

## 1. Chave SSH

No seu notebook, se ainda não tiver:

```bash
ssh-keygen -t ed25519 -C "matheus@notebook"
cat ~/.ssh/id_ed25519.pub
```

Cole essa saída em `ssh_authorized_keys` no `cloud-init.yaml`. **O setup
desabilita login por senha** — se a chave estiver errada, você fica de fora e
só o console web da Hetzner te salva.

## 2. Domínio

Registre em qualquer registrador. Duas opções sensatas:

- **`.com.br`** no [registro.br](https://registro.br) — ~R$ 40/ano, exige CPF
- **`.dev`** no Cloudflare Registrar — ~R$ 90/ano, vendido a preço de custo, e
  o TLD inteiro está no HSTS preload (HTTPS forçado no navegador de graça)

## 3. DNS na Cloudflare

Crie a conta, adicione o domínio, troque os nameservers no registrador.
Depois crie dois registros (o IP você só terá no passo 4 — volte aqui):

| Tipo | Nome | Conteúdo | Proxy |
|---|---|---|---|
| A | `@` | IP do servidor | **DNS only** (cinza) |
| A | `*` | IP do servidor | **DNS only** (cinza) |

O wildcard faz todo subdomínio futuro funcionar sem mexer em DNS de novo.

**Mantenha o proxy desligado no início.** Com a nuvem laranja ligada, o
Cloudflare termina o TLS por você e o Caddy passa a ver todo tráfego vindo do
IP deles — o que quebra rate limiting por IP e dificulta diagnosticar erro de
certificado. Ligue depois, se quiser esconder o IP de origem.

## 4. Criar o servidor

No console da Hetzner: **Add Server**.

- **Location:** Ashburn, VA (`ash`) — ~130 ms do Brasil contra ~200 ms da Alemanha
- **Image:** Ubuntu 24.04
- **Type:** aba **Arm64**, `CAX11` (2 vCPU, 4 GB, 40 GB)
- **Networking:** IPv4 + IPv6 (o IPv4 custa €0,50/mês; sem ele, metade da
  internet não te alcança)
- **Cloud config:** cole o `cloud-init.yaml` inteiro, já com sua chave
- **Firewalls:** crie um com as regras abaixo e aplique

Regras de entrada do Cloud Firewall (tudo o mais é bloqueado):

| Protocolo | Porta | Origem |
|---|---|---|
| TCP | 22 | `0.0.0.0/0`, `::/0` |
| TCP | 80 | `0.0.0.0/0`, `::/0` |
| TCP | 443 | `0.0.0.0/0`, `::/0` |
| UDP | 443 | `0.0.0.0/0`, `::/0` |

> Se você tivesse IP fixo, restringir a 22 à sua origem seria melhor. Com IP
> residencial dinâmico, isso te tranca do lado de fora no dia que o IP mudar —
> o `fail2ban` cobre o risco de força bruta.

**Conta nova na Hetzner costuma passar por verificação manual** (documento ou
pré-pagamento via PayPal), e isso pode levar de horas a um dia útil. Não deixe
para a véspera de precisar.

Anote o IP e volte ao passo 3 para criar os registros DNS.

## 5. Primeiro acesso

O cloud-init leva 2–4 minutos após o servidor aparecer como "running".

```bash
ssh matheus@SEU_IP

# Esperar o provisionamento terminar de verdade
cloud-init status --wait

# Conferir que nada falhou no meio
sudo journalctl -u cloud-init --no-pager | grep -iE 'fail|error' || echo "limpo"
```

Verificações que valem os 30 segundos:

```bash
docker run --rm hello-world          # docker funciona sem sudo
docker network ls | grep -E 'edge|data'
free -h                              # deve mostrar 2 Gi de swap
sudo ufw status
sudo fail2ban-client status sshd     # jail ativo (não só o serviço)
ssh root@SEU_IP                      # DEVE falhar — se entrar, algo deu errado
```

Opcional, mas ajuda a ler log: `sudo timedatectl set-timezone America/Sao_Paulo`.
Se fizer isso, lembre que o `backup.timer` passa a rodar 03:10 no horário de
Brasília em vez de UTC.

## 6. Subir a infraestrutura

Do seu notebook:

```bash
scp -r infra/ matheus@SEU_IP:/opt/stacks/_infra
```

No servidor:

```bash
cd /opt/stacks/_infra
cp .env.example .env
chmod 600 .env

# Gere a senha do banco e cole no .env, junto com DOMINIO e ACME_EMAIL
openssl rand -base64 32

nano .env
docker compose up -d
docker compose ps
```

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

Crie o bucket (Cloudflare R2 ou Backblaze B2, ambos com 10 GB grátis) e um
token de leitura/escrita. No servidor:

```bash
sudo cp scripts/backup.sh scripts/restore.sh /usr/local/bin/
sudo chmod 700 /usr/local/bin/backup.sh /usr/local/bin/restore.sh

sudo cp scripts/backup.env.example /etc/backup.env
sudo chmod 600 /etc/backup.env
sudo nano /etc/backup.env          # credenciais + RESTIC_PASSWORD

sudo cp systemd/backup.service systemd/backup.timer /etc/systemd/system/
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

Uma vez por mês, verificação profunda (lê os dados de fato, não só os
metadados):

```bash
source /etc/backup.env && sudo -E restic check --read-data-subset=10%
```

## 9. Primeiro projeto

```bash
scp -r scripts/ templates/ matheus@SEU_IP:~/
ssh matheus@SEU_IP
chmod +x ~/scripts/novo-projeto.sh
~/scripts/novo-projeto.sh meu-blog
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

---

## Operação

```bash
# Ver o que está consumindo RAM — o número que mais importa aqui
docker stats --no-stream

# Espaço em disco (40 GB acabam mais rápido do que parece)
df -h /  &&  docker system df

# Limpeza de imagens órfãs
docker image prune -a

# Atualizar um projeto
cd /opt/stacks/<projeto> && docker compose pull && docker compose up -d

# psql do seu notebook, sem expor o banco na internet
ssh -L 5432:localhost:5432 matheus@SEU_IP \
    'docker compose -f /opt/stacks/_infra/compose.yml exec postgres psql -U postgres'
```

## Armadilhas conhecidas

**O Docker ignora o `ufw`.** Ele escreve regras de iptables por fora e uma
porta publicada com `ports:` fica exposta na internet mesmo com o `ufw` negando.
Por isso o Cloud Firewall da Hetzner — que roda fora da VM e o Docker não
alcança — é a defesa que de fato conta. Regra do setup: **só o Caddy usa
`ports:`**. Todo o resto conversa pelas redes internas.

**Alias de rede é obrigatório em rede compartilhada.** Dois projetos com um
serviço chamado `app` na rede `edge` colidem no DNS e o Caddy passa a rotear
para o container errado, de forma intermitente. O template já define
`aliases: [PROJETO-app]`; não remova.

**Não apague o volume `caddy_data`.** Ali moram os certificados. Perder e
repedir tudo de uma vez pode bater no rate limit do Let's Encrypt (50
certificados por domínio registrado por semana).

**Aumento de disco na Hetzner é irreversível.** Você pode subir e descer de
plano à vontade (CAX11 ↔ CAX21) desde que não marque a opção de redimensionar
o disco. Se marcar uma vez, não dá mais para voltar a um plano menor.

**`docker compose down -v` apaga volumes.** No stack `_infra` isso significa o
banco inteiro. Use `down` sem `-v`.

## Quando subir para o CAX21

Vigie `docker stats` e `free -h`. Sinais de que 4 GB não bastam mais:

- swap em uso constante acima de ~500 MB
- containers sendo mortos por OOM (`dmesg | grep -i oom`)
- somatório dos limites de memória dos projetos passando de ~3 GB

O upgrade é um reboot de dois minutos no console (Rescale), sem migração e sem
mudar IP. CAX21 dobra tudo: 4 vCPU, 8 GB, 80 GB, por ~€10,99 ≈ R$ 73/mês.
Ao subir, dobre também `shared_buffers` e `effective_cache_size` no
`infra/compose.yml`.
