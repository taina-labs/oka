#!/usr/bin/env sh
# Monta a imagem do Tainá na sua própria caixa, a partir do código-fonte, para
# a CLI usar no lugar da imagem publicada.
#
# Uso:
#   ./build-image.sh                    # monta do main mais recente
#   TAINA_REF=v0.1.0 ./build-image.sh   # monta de uma tag específica
#
# Depois, aponte a CLI para essa imagem:
#
#   TAINA_IMAGE=taina:local taina setup
#
# (ou escreva TAINA_IMAGE=taina:local no taina.conf).

set -eu

SOURCE_DIR="taina-src"
SOURCE_URL="https://github.com/taina-labs/taina.git"
IMAGE="taina:local"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

step "Conferindo requisitos"
command -v docker >/dev/null 2>&1 || die "docker não está instalado. Veja https://docs.docker.com/get-docker/"
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
# 2. Construir.
# ---------------------------------------------------------------------------
step "Construindo a imagem $IMAGE (pode levar vários minutos na primeira vez)"
docker build -t "$IMAGE" "$SOURCE_DIR"

step "Imagem pronta"
say ""
say "A CLI usa a imagem publicada por padrão. Para usar esta:"
say ""
say "    TAINA_IMAGE=$IMAGE taina setup"
say ""
say "ou escreva TAINA_IMAGE=$IMAGE no taina.conf e rode 'taina setup'."
say ""
say "Para publicar uma versão nova depois de mexer no código, rode este script"
say "de novo e depois 'taina update'."
