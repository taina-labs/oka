# Oka

> Em Tupi, _oka_ é a casa. Este repositório é a casa do [Tainá](https://github.com/taina-labs/taina):
> a orquestração que coloca o servidor da sua comunidade no ar numa caixa
> (Raspberry Pi, mini PC ou VPS).

O Oka não contém o código do Tainá. Ele baixa a imagem publicada e sobe tudo
com um comando: banco de dados, aplicação e um proxy reverso com HTTPS
automático. É o "deploy é produto": uma comunidade não-técnica instala em menos
de 30 minutos e nunca tem medo de atualizar.

## Instalação

O passo a passo completo, para quem nunca fez isso, está no
[guia de instalação](https://github.com/taina-labs/tekoa/blob/main/guias/instalacao.md).
Resumido:

Numa caixa com [Docker](https://docs.docker.com/get-docker/) e o plugin Compose:

```sh
git clone https://github.com/taina-labs/oka.git
cd oka
./install.sh
```

O instalador gera os segredos, escreve o `.env`, sobe os serviços e imprime o
endereço do assistente de configuração. Para um domínio público com certificado
real (Let's Encrypt automático):

```sh
TAINA_DOMAIN=nuvem.suacomunidade.org ./install.sh
```

Deixe o `TAINA_DOMAIN` vazio numa caixa de rede local ou acessada por
Tailscale/Headscale: o Caddy usa um certificado local, e o guia de acesso
remoto explica como ter um certificado de verdade sem domínio próprio.

### Se a imagem publicada ainda não existir

O `install.sh` baixa a imagem do Tainá do registro. Ela é publicada junto de
cada release, então antes do primeiro lançamento ela ainda não está lá. Nesse
caso, monte a imagem na sua própria máquina a partir do código:

```sh
./build-image.sh
./install.sh
```

O `build-image.sh` clona o código do Tainá, compila a imagem localmente e
escreve um `docker-compose.override.yml` que o Compose lê sozinho. A partir
aí, o `install.sh` e o `update.sh` passam a usar a imagem local. Para voltar ao
comportamento normal, apague esse arquivo.

### Se a caixa já rodou uma versão anterior do compose

O script que cria o papel do aplicativo no banco
(`deploy/initdb/01-taina-app-role.sh`) roda uma única vez, num volume
`postgres_data` vazio. Numa caixa que já subiu o compose antigo, o volume já
está populado, o papel `taina_app` não chega a ser criado e o app não conecta
no banco. Duas saídas:

- Recomeçar do zero: `docker compose down -v` e depois `./install.sh` de novo.
  Antes do primeiro lançamento estável não há dados reais a perder.
- Manter o volume: crie o papel `taina_app` à mão, seguindo as queries do
  próprio `deploy/initdb/01-taina-app-role.sh`.

## Atualização

```sh
./update.sh
```

Baixa a imagem mais recente, reinicia e confere a saúde. As migrações de banco
rodam sozinhas no boot, então atualizar é seguro. Antes de reiniciar, o
`update.sh` guarda uma cópia do banco em `rollback/` e anota a imagem que
estava no ar: se a versão nova não voltar a ficar saudável, as instruções
exatas de reversão aparecem na saída do script. Se você montou a imagem
localmente com o `build-image.sh`, o `update.sh` reconstrói em vez de baixar.

## O que sobe

| Serviço | Papel |
| --- | --- |
| `db` | PostgreSQL 18 (dados da comunidade) |
| `app` | a aplicação Tainá (imagem `ghcr.io/taina-labs/taina`) |
| `caddy` | proxy reverso, única porta de entrada, HTTPS automático |

Apenas o Caddy fica exposto à rede. A aplicação também responde em
`127.0.0.1:4000`, mas só dentro da própria caixa: é esse endereço que o
`tailscale serve` usa para publicar o Tainá sem abrir portas. Os dados ficam
em volumes nomeados (`postgres_data`, `storage_data`, `backups_data`) ou nos
diretórios do host apontados em `TAINA_STORAGE_DIR` e `TAINA_BACKUP_DIR` no
`.env`, e persistem entre reinícios e atualizações.

Quem sobe os serviços na mão (`docker compose up -d`, sem os scripts) fica com
o `Caddyfile.local` por padrão; numa caixa com domínio público, exporte
`TAINA_CADDYFILE=Caddyfile` antes, que é o que o `install.sh` e o `update.sh`
fazem por você.

## Guias do operador

Documentação completa no repositório [Tekoá](https://github.com/taina-labs/tekoa).
Para começar, o
[guia de instalação](https://github.com/taina-labs/tekoa/blob/main/guias/instalacao.md),
que é o passo a passo do zero:
- [Acesso remoto](https://github.com/taina-labs/tekoa/blob/main/guias/acesso-remoto.md)
  (Tailscale recomendado, Headscale soberano, WireGuard avançado).
- [Runbook de backup e restauração](https://github.com/taina-labs/tekoa/blob/main/guias/runbook-backup-restore.md)
  (procedimento e ensaio).
- [Hardware e montagem](https://github.com/taina-labs/tekoa/blob/main/guias/compras-hardware.md).

## Licença

[GNU Affero General Public License v3.0](LICENSE), a mesma do Tainá.
