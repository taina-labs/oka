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

## Atualização

```sh
./update.sh
```

Baixa a imagem mais recente, reinicia e confere a saúde. As migrações de banco
rodam sozinhas no boot, então atualizar é seguro. Se você montou a imagem
localmente com o `build-image.sh`, o `update.sh` reconstrói em vez de baixar.

## O que sobe

| Serviço | Papel |
| --- | --- |
| `db` | PostgreSQL 18 (dados da comunidade) |
| `app` | a aplicação Tainá (imagem `ghcr.io/taina-labs/taina`) |
| `caddy` | proxy reverso, única porta de entrada, HTTPS automático |

Apenas o Caddy fica exposto. A aplicação fala HTTP só na rede interna do
Compose. Os dados ficam em volumes nomeados (`postgres_data`, `storage_data`,
`backups_data`) e persistem entre reinícios e atualizações.

## Guias do operador

Documentação completa no repositório [Tekoá](https://github.com/taina-labs/tekoa).
Para começar, o
[guia de instalação](https://github.com/taina-labs/tekoa/blob/main/guias/instalacao.md),
que é o passo a passo do zero:
- Acesso remoto (Tailscale recomendado, Headscale soberano, WireGuard avançado):
  `guias/acesso-remoto.md`.
- Runbook de backup e restauração (procedimento e ensaio):
  `guias/runbook-backup-restore.md`.
- Hardware e montagem: `guias/compras-hardware.md`.

## Licença

[GNU Affero General Public License v3.0](LICENSE), a mesma do Tainá.
