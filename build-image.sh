#!/usr/bin/env sh
# Monta a imagem do Tainá na sua própria caixa, a partir do código-fonte.
#
# Para que serve: o install.sh normalmente baixa a imagem publicada no registro.
# Antes do primeiro lançamento (ou quando você quer mudar o código e ver o
# efeito), essa imagem pode não existir. Este script constrói ela localmente e
# escreve um docker-compose.override.yml, que o Docker Compose carrega sozinho.
# A partir daí install.sh, update.sh e qualquer "docker compose" da pasta passam
# a usar a imagem local, sem precisar mexer no .env.
#
# Uso:
#   ./build-image.sh              # constrói do main mais recente
#   TAINA_REF=v0.1.0 ./build-image.sh   # constrói de uma tag específica
#
# Depois: ./install.sh
#
# Para voltar a usar a imagem do registro, apague o
# docker-compose.override.yml.

set -eu

COMPOSE="docker compose"
SOURCE_DIR="taina-src"
SOURCE_URL="https://github.com/taina-labs/taina.git"
IMAGE="taina:local"
OVERRIDE_FILE="docker-compose.override.yml"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

step "Conferindo requisitos"
command -v docker >/dev/null 2>&1 || die "docker não está instalado. Veja https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "o plugin docker compose está faltando. Instale o Docker Compose v2."
command -v git >/dev/null 2>&1 || die "git não está instalado."

REF="${TAINA_REF:-main}"

# ---------------------------------------------------------------------------
# 1. Código-fonte.
# ---------------------------------------------------------------------------
if [ -d "$SOURCE_DIR/.git" ]; then
  step "Atualizando o código em $SOURCE_DIR"
  git -C "$SOURCE_DIR" fetch --quiet origin
  git -C "$SOURCE_DIR" checkout --quiet "$REF"
  git -C "$SOURCE_DIR" pull --quiet --ff-only origin "$REF" 2>/dev/null ||
    git -C "$SOURCE_DIR" reset --quiet --hard "origin/$REF"
else
  step "Baixando o código do Tainá ($REF)"
  [ -e "$SOURCE_DIR" ] && die "o caminho $SOURCE_DIR existe mas não é um repositório git. Remova-o e rode de novo."
  git clone --quiet --branch "$REF" --depth 1 "$SOURCE_URL" "$SOURCE_DIR"
fi

# ---------------------------------------------------------------------------
# 2. Construir. Multi-arch quando o buildx está disponível, senão só a
# arquitetura da caixa (o suficiente para instalar aqui).
# ---------------------------------------------------------------------------
step "Construindo a imagem $IMAGE (pode levar vários minutos na primeira vez)"
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load -t "$IMAGE" "$SOURCE_DIR"
else
  docker build -t "$IMAGE" "$SOURCE_DIR"
fi

# ---------------------------------------------------------------------------
# 3. Fazer o Compose usar a imagem local.
# ---------------------------------------------------------------------------
step "Apontando o Compose para a imagem local"
cat > "$OVERRIDE_FILE" <<EOF
# Gerado por build-image.sh. Apague este arquivo para voltar a usar a imagem
# publicada no registro.
services:
  app:
    image: $IMAGE
    # A imagem é local: nunca tentar baixar do registro.
    pull_policy: never
EOF
say "Escrevi $OVERRIDE_FILE."

step "Imagem pronta"
say ""
say "Rode agora:"
say ""
say "    ./install.sh"
say ""
say "Para publicar uma versão nova depois de mexer no código, rode este script"
say "de novo e depois ./update.sh."
