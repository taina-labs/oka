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
OVERRIDE_FILE="docker-compose.override.yml"

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "não encontrei o $ENV_FILE. Rode ./install.sh primeiro."

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
  if [ -f "$OVERRIDE_FILE" ]; then
    say "Sua imagem é local. Para voltar para uma versão anterior do código,"
    say "rode de novo com uma tag antiga:"
    say "    TAINA_REF=v0.1.0 ./build-image.sh && ./update.sh"
  else
    say "Se precisar, volte para a imagem anterior trocando TAINA_IMAGE no $ENV_FILE"
    say "para a tag antiga (ex.: ghcr.io/taina-labs/taina:vX.Y.Z) e rodando"
    say "./update.sh de novo."
  fi
  die "checagem de saúde após a atualização falhou"
fi

step "Atualização concluída"
say "O Tainá está no ar na versão mais recente."
