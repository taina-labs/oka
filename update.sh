#!/usr/bin/env sh
# Atualiza o Tainá: baixa a imagem nova, reinicia e confere a saúde. As migrações
# de banco rodam sozinhas no boot do release (o CMD do container chama
# Taina.Release.migrate antes de iniciar o servidor), então aqui só precisamos
# baixar a imagem e subir de novo.
#
# Uso:
#   ./update.sh
#
# Sai com código diferente de zero se o download falhar ou se o app não voltar a
# ficar saudável, para que um operador (ou um cron) perceba o problema.

set -eu

ENV_FILE=".env"
COMPOSE="docker compose"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "não encontrei o $ENV_FILE. Rode ./install.sh primeiro."

step "Baixando a imagem mais recente"
$COMPOSE pull

step "Reiniciando com a versão nova (migrações rodam no boot)"
$COMPOSE up -d

step "Conferindo se o Tainá voltou a ficar saudável"
HEALTHY=0
i=1
while [ "$i" -le 60 ]; do
  if curl -fsk "https://localhost/health" >/dev/null 2>&1 ||
     curl -fs "http://localhost:4000/health" >/dev/null 2>&1; then
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
  say "Se precisar, volte para a imagem anterior trocando TAINA_IMAGE no $ENV_FILE"
  say "para a tag antiga (ex.: ghcr.io/taina-labs/taina:vX.Y.Z) e rodando"
  say "./update.sh de novo."
  die "checagem de saúde após a atualização falhou"
fi

step "Atualização concluída"
say "O Tainá está no ar na versão mais recente."
