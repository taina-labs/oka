#!/usr/bin/env sh
# Atualiza o Tainá: baixa a imagem nova, reinicia e confere a saúde. As migrações
# de banco rodam sozinhas no boot do release (o CMD do container chama
# Taina.Release.migrate antes de iniciar o servidor), então aqui só precisamos
# baixar a imagem e subir de novo.
#
# Antes de reiniciar, o script guarda uma cópia do banco em rollback/ e anota
# a imagem que estava no ar: se a versão nova não voltar a ficar saudável, as
# instruções exatas de reversão aparecem na saída.
#
# Uso:
#   ./update.sh
#
# Sai com código diferente de zero se o download falhar ou se o app não voltar a
# ficar saudável, para que um operador (ou um cron) perceba o problema.

set -eu

ENV_FILE=".env"
COMPOSE="docker compose"
OVERRIDE_FILE="docker-compose.override.yml"
ROLLBACK_DIR="rollback"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "não encontrei o $ENV_FILE. Rode ./install.sh primeiro."

# ---------------------------------------------------------------------------
# Estado atual: o que reverter, para onde o Caddy aponta.
#
# Os nomes saem do .env resolvidos, para que as instruções de reversão saiam
# prontas de copiar e colar, sem adivinhação.
# ---------------------------------------------------------------------------
if [ -f "$OVERRIDE_FILE" ]; then
  # build-image.sh sempre marca a imagem local com este nome.
  IMAGE_REF="taina:local"
else
  IMAGE_REF="$(grep '^TAINA_IMAGE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  IMAGE_REF="${IMAGE_REF:-ghcr.io/taina-labs/taina:latest}"
fi
DB_USER="$(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2-)"
DB_USER="${DB_USER:-taina}"
DB_NAME="$(grep '^POSTGRES_DB=' "$ENV_FILE" | cut -d= -f2-)"
DB_NAME="${DB_NAME:-taina}"

# O Caddy carrega a configuração apontada em TAINA_CADDYFILE (mesma regra do
# install.sh): com domínio público, o Caddyfile; sem domínio, o Caddyfile.local.
DOMAIN_VALUE="$(grep '^TAINA_DOMAIN=' "$ENV_FILE" | cut -d= -f2-)"
if [ -n "$DOMAIN_VALUE" ]; then
  export TAINA_CADDYFILE="Caddyfile"
else
  export TAINA_CADDYFILE="Caddyfile.local"
fi

# Imagem que está no ar agora: é ela que a reversão vai re-marcar se a versão
# nova não voltar a ficar saudável.
STAMP="$(date +%Y%m%d-%H%M%S)"
OLD_IMAGE=""
APP_CONTAINER="$($COMPOSE ps --all --quiet app 2>/dev/null | head -n 1 || true)"
if [ -n "$APP_CONTAINER" ]; then
  OLD_IMAGE="$(docker inspect --format '{{.Image}}' "$APP_CONTAINER")"
fi

# Imagem construída na própria caixa (build-image.sh): não há registro para
# baixar. A atualização é reconstruir e subir de novo.
if [ -f "$OVERRIDE_FILE" ]; then
  step "Esta instalação usa uma imagem local ($OVERRIDE_FILE)"
  say "Para atualizar, reconstrua a imagem antes de continuar:"
  say ""
  say "    ./build-image.sh"
  say ""
  ./build-image.sh
else
  step "Baixando a imagem mais recente"
  $COMPOSE pull
fi

# Backup do banco antes de mexer em qualquer coisa: se a migração da versão
# nova estragar algo, é ele que permite voltar sem perder os dados. Sem
# container do app não há nada a proteger (primeira instalação), então pulamos.
if [ -n "$OLD_IMAGE" ]; then
  step "Guardando o estado atual (backup do banco em $ROLLBACK_DIR/)"
  mkdir -p "$ROLLBACK_DIR"
  DUMP_FILE="$ROLLBACK_DIR/taina-db-$STAMP.dump"
  if ! $COMPOSE exec -T db pg_dump --username "$DB_USER" --format=custom "$DB_NAME" > "$DUMP_FILE"; then
    rm -f "$DUMP_FILE"
    die "o backup pré-atualização falhou; não vou atualizar por cima de um banco sem cópia. Veja os logs do banco."
  fi
  say "Backup do banco salvo em $DUMP_FILE."
fi

step "Reiniciando com a versão nova (migrações rodam no boot)"
$COMPOSE up -d

step "Conferindo se o Tainá voltou a ficar saudável"
HEALTHY=0
i=1
while [ "$i" -le 60 ]; do
  # Sondagem de dentro do container: não depende de curl no host, de
  # certificado nem do Caddy. Responde 200 só quando o app e o banco estão de pé.
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
  say "O Tainá não voltou a ficar saudável depois da atualização. Veja os logs:"
  say "    docker compose logs -f app"
  say ""
  if [ -n "$OLD_IMAGE" ]; then
    say "Para reverter à versão anterior, com a imagem que estava no ar:"
    say ""
    say "    docker tag $OLD_IMAGE $IMAGE_REF"
    say "    $COMPOSE up -d"
    say ""
    # O restore basta por si: o dump em formato custom grava o dono real de
    # cada objeto (as migrações rodam como taina_app) e o pg_restore roda aqui
    # como o superusuário do bootstrap, então recria tudo com os donos que o
    # dump registrou. Não há REASSIGN OWNED BY nesta receita, e é de propósito:
    # o POSTGRES_USER do bootstrap é um papel fixo do Postgres, e um REASSIGN
    # partindo dele sempre erra.
    say "O backup do banco feito antes de atualizar está em $DUMP_FILE. Se as"
    say "migrações da versão nova estragarem os dados, restaure-o com:"
    say ""
    say "    $COMPOSE exec -T db pg_restore --clean --if-exists --username $DB_USER --dbname $DB_NAME < $DUMP_FILE"
    say ""
  fi
  if [ -f "$OVERRIDE_FILE" ]; then
    say "Sua imagem é local. Para construir uma versão anterior do código:"
    say "    TAINA_REF=v0.1.0 ./build-image.sh && ./update.sh"
  else
    say "Para tentar outra versão específica, troque TAINA_IMAGE no $ENV_FILE"
    say "pela tag desejada (ex.: ghcr.io/taina-labs/taina:vX.Y.Z) e rode"
    say "./update.sh de novo."
  fi
  die "checagem de saúde após a atualização falhou"
fi

step "Atualização concluída"
say "O Tainá está no ar na versão mais recente."
if [ -n "$OLD_IMAGE" ]; then
  say "O backup pré-atualização ficou em $DUMP_FILE (pode apagar quando quiser)."
fi
