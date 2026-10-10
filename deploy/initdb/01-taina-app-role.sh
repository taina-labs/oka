#!/bin/sh
# Cria o papel de aplicação que o Tainá usa para falar com o banco: taina_app,
# sem superpoderes e sem bypass de RLS. Numa base nova as migrações rodam como
# taina_app (a conexão do app usa esse papel), então é ele o dono dos schemas
# e das tabelas, e não o superusuário (POSTGRES_USER). O desenho segue de pé
# porque as migrações aplicam FORCE ROW LEVEL SECURITY, que sujeita o próprio
# dono às políticas de isolamento por comunidade.
#
# O script roda uma única vez, na inicialização de um volume vazio
# (/docker-entrypoint-initdb.d), com POSTGRES_USER, POSTGRES_PASSWORD e
# POSTGRES_DB no ambiente e conexão de superusuário via socket local.
#
# Mantenha em sincronia com o job docker-smoke do repositório taina
# (taina/.github/workflows/docker-smoke.yml), que cria o mesmo papel para os
# testes de fumaça.

set -eu

APP_ROLE="taina_app"

psql_cmd() {
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}

# O guard de existência fica no shell de propósito: o psql não substitui
# :'var' dentro de blocos DO $$, então um "CREATE ROLE if not exists" em
# PL/pgSQL não conseguiria receber a senha interpolada. Consultamos o
# catálogo antes e passamos a senha pelo :'app_password', que o psql escapa.
if [ "$(psql_cmd -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$APP_ROLE'")" = "1" ]; then
  echo "papel $APP_ROLE já existe; seguindo sem alterar"
else
  psql_cmd -v app_password="$POSTGRES_PASSWORD" \
    -c "CREATE ROLE $APP_ROLE LOGIN PASSWORD :'app_password' NOSUPERUSER NOBYPASSRLS;"
fi

# CONNECT: abrir conexão no banco. CREATE (no database): criar os schemas das
# aplicações (maraca, ybira, guara) nas migrations.
psql_cmd -c "GRANT CONNECT, CREATE ON DATABASE $POSTGRES_DB TO $APP_ROLE;"

# USAGE: enxergar o schema public (no PostgreSQL 15+ ele não dá mais CREATE
# para o público). CREATE: criar as tabelas das migrations nele.
psql_cmd -c "GRANT USAGE, CREATE ON SCHEMA public TO $APP_ROLE;"
