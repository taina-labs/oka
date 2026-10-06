#!/usr/bin/env sh
# Instalador do Tainá. Gera segredos, escreve o .env, sobe os serviços e espera
# o servidor ficar saudável. Pode rodar mais de uma vez sem perigo: um .env que
# já existe nunca é sobrescrito, então seus segredos e seus dados continuam no
# lugar.
#
# Uso:
#   ./install.sh                 # caixa local, HTTPS com certificado local
#   TAINA_DOMAIN=nuvem.meugrupo.org ./install.sh   # domínio público + cert real
#
# Precisa de: docker (com o plugin compose) e openssl. Nada além disso.

set -eu

ENV_FILE=".env"
COMPOSE="docker compose"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Conferir o pouco que precisamos.
# ---------------------------------------------------------------------------
step "Conferindo requisitos"
command -v docker >/dev/null 2>&1 || die "docker não está instalado. Veja https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "o plugin docker compose está faltando. Instale o Docker Compose v2."
command -v openssl >/dev/null 2>&1 || die "openssl não está instalado."
if command -v curl >/dev/null 2>&1; then
  say "Tudo certo: docker, docker compose, openssl e curl estão presentes."
else
  # curl é opcional: a checagem de saúde roda de dentro do container do app, e
  # a imagem já traz o curl. Sem curl no host, o aviso sobre o certificado local
  # do navegador fica de fora, mas a instalação segue normal.
  say "Tudo certo: docker, docker compose e openssl estão presentes."
  say "curl não está instalado. Não é problema: a checagem de saúde roda de"
  say "dentro do container. Só o aviso do certificado local fica de fora no fim."
fi

# ---------------------------------------------------------------------------
# 2. Escrever o .env uma única vez. Rodar de novo nunca apaga os segredos.
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  step "Encontrei um $ENV_FILE existente, vou mantê-lo"
  say "Seus segredos e ajustes serão reaproveitados. Só apague o $ENV_FILE se"
  say "quiser começar do zero (isso vai te trancar para fora do banco atual)."
else
  step "Criando o $ENV_FILE com segredos novos"
  SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
  # Senha do banco só com letras e números (sem caracteres que o shell ou a URL
  # precisariam escapar).
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  TAINA_DOMAIN_VALUE="${TAINA_DOMAIN:-}"
  if [ -n "$TAINA_DOMAIN_VALUE" ]; then
    PHX_HOST_VALUE="$TAINA_DOMAIN_VALUE"
  else
    PHX_HOST_VALUE="localhost"
  fi

  umask 077
  cat > "$ENV_FILE" <<EOF
# Gerado pelo install.sh. Trate este arquivo como segredo: ele tem a senha do
# banco e a chave que assina as sessões. Não versione (não faça commit).

# Imagem do container. Por padrão usa a imagem publicada do Tainá.
TAINA_IMAGE=ghcr.io/taina-labs/taina:latest

# Domínio público. Deixe vazio para uma caixa em rede local/overlay (certificado
# local); preencha com seu domínio (com as portas 80/443 acessíveis) para um
# certificado Let's Encrypt automático.
TAINA_DOMAIN=$TAINA_DOMAIN_VALUE

# Hostname que o app usa para montar as URLs.
PHX_HOST=$PHX_HOST_VALUE

# Segredos (gerados uma vez, não altere na mão).
SECRET_KEY_BASE=$SECRET_KEY_BASE
POSTGRES_USER=taina
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=taina

# Backups agendados. Mude para true depois de montar um disco de backup.
BACKUP_ENABLED=false
EOF
  say "Escrevi o $ENV_FILE (só você consegue ler)."
fi

# ---------------------------------------------------------------------------
# 3. Baixar e subir os serviços.
# ---------------------------------------------------------------------------
OVERRIDE_FILE="docker-compose.override.yml"

if [ -f "$OVERRIDE_FILE" ]; then
  # build-image.sh escreveu este override: a imagem foi montada nesta máquina e
  # não existe no registro. Nem faz sentido tentar baixar.
  step "Usando a imagem local (build-image.sh já rodou)"
  say "Para voltar a usar a imagem publicada, apague o $OVERRIDE_FILE."
else
  step "Baixando a imagem do Tainá"
  IMAGE="$(grep '^TAINA_IMAGE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  IMAGE="${IMAGE:-ghcr.io/taina-labs/taina:latest}"

  if ! $COMPOSE pull; then
    # Uma falha no download nem sempre é problema: se a imagem já estiver nesta
    # máquina (instalação repetida), seguimos com ela. Se não estiver, o
    # pull_policy `missing` tentaria construir e a mensagem seria confusa, então
    # falamos aqui com a instrução certa.
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      say "Não consegui baixar $IMAGE do registro, mas ela já está nesta máquina."
      say "Seguindo com a imagem local."
    else
      say ""
      say "Não consegui baixar a imagem do Tainá ($IMAGE), e ela não está nesta máquina."
      say ""
      say "Se você está antes do primeiro lançamento, a imagem ainda pode não"
      say "existir no registro. Você pode montar a imagem na sua própria caixa:"
      say ""
      say "    ./build-image.sh"
      say ""
      say "Depois rode o ./install.sh de novo."
      die "imagem do Tainá indisponível"
    fi
  fi
fi

step "Subindo o Tainá (banco, app e proxy reverso)"
$COMPOSE up -d

# ---------------------------------------------------------------------------
# 4. Esperar o app responder que está saudável.
#
# A sondagem roda de dentro do container do app, em http://localhost:4000/health.
# Ela é a fonte da verdade: o endpoint só responde 200 quando o app subiu E o
# PostgreSQL respondeu, que é a condição que install.sh precisa confirmar. Não
# depende de curl no host, nem de certificado, nem de o Caddy já ter emitido o
# certificado dele (com TAINA_DOMAIN, o Caddy serve só aquele domínio, então
# sondar https://localhost nunca bateria, e a porta 4000 não é publicada).
#
# O Caddy é conferido depois, em separado e sem matar a instalação: emitir um
# certificado Let's Encrypt leva dezenas de segundos e não é motivo para
# declarar falha com o app já no ar.
# ---------------------------------------------------------------------------
step "Esperando o Tainá subir (no primeiro boot pode levar um minuto)"
HEALTHY=0
i=1
while [ "$i" -le 60 ]; do
  if $COMPOSE exec -T app curl -fsS http://localhost:4000/health >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  printf '.'
  sleep 5
  i=$((i + 1))
done
printf '\n'

if [ "$HEALTHY" -ne 1 ]; then
  say "O Tainá não ficou saudável a tempo. Veja os logs com:"
  say "    docker compose logs -f app"
  die "a checagem de saúde na inicialização falhou"
fi

# ---------------------------------------------------------------------------
# 5. Dizer para o operador o próximo passo.
# ---------------------------------------------------------------------------
DOMAIN_VALUE="$(grep '^TAINA_DOMAIN=' "$ENV_FILE" | cut -d= -f2-)"
if [ -n "$DOMAIN_VALUE" ]; then
  URL="https://$DOMAIN_VALUE/setup"
else
  URL="https://localhost/setup"
fi

step "O Tainá está no ar"
say ""
say "Abra o assistente de configuração para criar sua comunidade e a conta de"
say "administrador:"
say ""
say "    $URL"
say ""

# Aviso honesto, nunca fatal: o app está no ar; o Caddy é que pode ainda estar
# emitindo o certificado.
if command -v curl >/dev/null 2>&1; then
  say "Conferindo o proxy reverso (na primeira vez leva alguns segundos)..."
  PROXY_OK=0
  i=1
  while [ "$i" -le 24 ]; do
    if curl -fsS -o /dev/null "$URL" 2>/dev/null; then
      PROXY_OK=1
      break
    fi
    printf '.'
    sleep 5
    i=$((i + 1))
  done
  printf '\n'
  if [ "$PROXY_OK" -eq 1 ]; then
    say "O endereço acima já responde."
  else
    say "O app está saudável, mas $URL ainda não respondeu."
    say "O Caddy pode estar esperando emitir o certificado. Veja com:"
    say "    docker compose logs -f caddy"
  fi
  say ""
fi

if [ -z "$DOMAIN_VALUE" ]; then
  say "Você está com um certificado local, então o navegador vai avisar na"
  say "primeira vez. Isso é esperado numa caixa de rede local. Para acessar o"
  say "Tainá de fora da sua rede sem avisos, siga o guia de acesso remoto"
  say "(Tailscale é o caminho recomendado)."
fi
say ""
say "Comandos úteis:"
say "    docker compose logs -f app     # acompanhar os logs do app"
say "    docker compose logs -f db      # acompanhar os logs do banco"
say "    ./update.sh                    # atualizar para a versão mais recente"
