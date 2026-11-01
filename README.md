# Oka

> Em Tupi, _oka_ é a casa. Este repositório é a casa do [Tainá](https://github.com/taina-labs/taina):
> a CLI `taina`, que opera o servidor da sua comunidade numa caixa (Raspberry
> Pi, mini PC ou VPS), e o módulo NixOS para quem roda Nix.

O Oka não contém o código do Tainá. Ele traz a CLI `taina`, que baixa a imagem
publicada e sobe tudo com um comando. É o "deploy é produto": uma comunidade
não-técnica instala em menos de 30 minutos e nunca tem medo de atualizar.

## Instalação

O passo a passo completo, para quem nunca fez isso, está no
[guia de instalação](https://github.com/taina-labs/tekoa/blob/main/guias/instalacao.md).
Resumido, numa caixa com [Docker](https://docs.docker.com/get-docker/):

```sh
# a CLI, por Nix (ou baixe o binário da release)
nix build github:taina-labs/oka
sudo install -m755 result/bin/taina /usr/local/bin/taina

# instala e inicia o Tainá
taina setup
```

Na primeira execução interativa, `setup` pergunta as opções básicas, mostra um
resumo e pede confirmação. Enter aceita cada valor padrão; cancelar não grava a
configuração nem cria o container. Sem terminal interativo, usa os defaults, o
ambiente e as flags sem esperar entrada. O segredo de sessão é gerado pela CLI e
o arquivo `taina.conf` é criado com permissão `0600`.
Quando esse arquivo já existe, não há assistente: `setup` valida e aplica a
configuração atual.

O endereço local impresso pela CLI usa HTTP em `127.0.0.1`. A CLI não configura
TLS. Se definir um domínio, o endereço HTTPS público só funcionará depois que
um proxy ou Tailscale Serve configurar TLS e encaminhar para a porta local.

### Arquivo de configuração

Por padrão, a CLI lê e grava `taina.conf` no diretório atual. Selecione outro
arquivo com `--config` ou `TAINA_CONFIG`:

```sh
taina --config /srv/taina/taina.conf setup
taina --config=/srv/taina/taina.conf setup
TAINA_CONFIG=/srv/taina/taina.conf taina setup
# Também aceito:
taina setup --config /srv/taina/taina.conf
```

A precedência é `--config` > `TAINA_CONFIG` > `./taina.conf`. Para as opções,
flags e ambiente sobrescrevem o arquivo durante a execução; esses overrides não
alteram silenciosamente um arquivo existente. `--domain` tem precedência sobre
`TAINA_DOMAIN`, que tem precedência sobre o valor do arquivo.

Exemplo de `taina.conf`:

```ini
TAINA_IMAGE=ghcr.io/taina-labs/taina:latest
TAINA_CONTAINER=taina-app
TAINA_NETWORK=taina
TAINA_DOMAIN=nuvem.suacomunidade.org
TAINA_DB_DIR=
TAINA_STORAGE_DIR=
TAINA_BACKUP_DIR=
SECRET_KEY_BASE=
TAINA_HOST_PORT=4000
TAINA_UPDATE_CHECK=false
TAINA_BACKUP_ENABLED=false
```

Diretórios vazios usam volumes nomeados. `SECRET_KEY_BASE` pode ficar vazio: o
`setup` gera o segredo e o acrescenta sem reformatar o restante do arquivo.
Booleanos aceitos: `true`, `false`, `1` e `0`. Comentários e chaves têm de ser
As chaves devem ser conhecidas e únicas; comentários são preservados. A CLI
aponta o arquivo e a linha quando encontra um erro.

Depois de editar o arquivo, rode `taina setup` para aplicar as mudanças. A CLI
valida a configuração e recria somente o container quando necessário, mantendo
volumes e diretórios de dados. `taina restart` apenas reinicia o container
existente; `taina update` continua responsável por atualizar a imagem.

### Expor ao mundo

A CLI **não configura TLS**, e isso é uma decisão: quem expõe a caixa é você.

- **Tailscale (recomendado).** `tailscale serve --bg 4000` publica a caixa com
  HTTPS de verdade, sem abrir porta nenhuma. Veja o
  [guia de acesso remoto](https://github.com/taina-labs/tekoa/blob/main/guias/acesso-remoto.md).
- **Seu proxy** (Caddy, nginx, cloudflared, ...) na frente do `127.0.0.1:4000`.
  O `deploy/Caddyfile` é um exemplo de Caddy com Let's Encrypt.

### Se a imagem publicada ainda não existir

O `setup` baixa a imagem do registro. Para montar a imagem na própria caixa, a
partir do código:

```sh
./build-image.sh
TAINA_IMAGE=taina:local taina setup
```

## Comandos

```
taina setup [--domain D]     instala, configura ou reconfigura o Taina
taina up | down | restart    sobe, para (os dados ficam) e reinicia
taina update [--tag T]       baixa e sobe a versao nova (guarda rollback)
taina status                 estado do servico
taina logs [-f] [--tail N]   logs
taina health                 checa /health
taina backend                imprime o backend e os caminhos
taina backup [--out DIR]     backup (banco + storage)
taina restore <arquivo>      restauracao (a CLI para o Taina e volta)
taina doctor                 diagnostico da caixa
taina version                versao da CLI
```

Config no `taina.conf` (chave=valor), sobrescrita pelo ambiente: `TAINA_IMAGE`,
`TAINA_CONTAINER`, `TAINA_NETWORK`, `TAINA_DOMAIN`, `TAINA_HOST_PORT`,
`TAINA_DB_DIR`, `TAINA_STORAGE_DIR`, `TAINA_BACKUP_DIR`, `TAINA_UPDATE_CHECK`,
`TAINA_BACKUP_ENABLED` e `SECRET_KEY_BASE`. Diretórios vazios usam volumes
nomeados. `taina --help` lista também `TAINA_CONFIG` e as opções do backend.

## Atualização

```sh
taina update
```

Baixa a imagem nova, guarda uma cópia do banco em `rollback/`, recria o
container e confere a saúde. As migrações rodam sozinhas no boot.

### Depois de atualizar: regenerar as miniaturas (uma vez por atualização)

A atualização pode trazer um jeito novo de gerar miniatura (ou o conserto de
uma falha). As imagens que já estavam na caixa não são reprocessadas sozinhas:
quem tinha miniatura segue com a antiga, e a que falhou antes fica "pendente"
para sempre. É um passo de pós-deploy, e não roda de novo a cada boot:

```sh
mix taina.thumbnails.regenerate
```

A tarefa é do Mix, então roda de um código-fonte do Tainá apontando para o
banco da caixa (o mesmo arranjo do
[runbook de senha](https://github.com/taina-labs/tekoa/blob/main/guias/runbook-senha.md)):

```sh
mix deps.get
DATABASE_PATH=/caminho/da/taina.db mix taina.thumbnails.regenerate
```

Ela é idempotente: quem já tem miniatura regenera por cima, e o resumo sai no
fim. A caixa pode estar no ar durante a tarefa.

## Backup e restauração

```sh
taina backup --out /mnt/usb
taina restore /mnt/usb/taina-backup-AAAAMMDDTHHMMSSZ.tar.gz
```

O `restore` para o Tainá, roda a restauração num container avulso sobre os
mesmos dados (o arquivo do banco é substituído, então nada pode estar aberto) e
sobe de novo. O `backup` roda com o Tainá no ar.

O procedimento completo e o ensaio (drill) estão no
[runbook de backup](https://github.com/taina-labs/tekoa/blob/main/guias/runbook-backup-restore.md).

## O que sobe

| Serviço | Papel |
| --- | --- |
| `taina-app` | o Tainá, com o banco SQLite num arquivo |

Só o container do app. A rede `taina`, os dados em volumes nomeados (`taina_db`,
`taina_storage`, `taina_backups`) ou em discos apontados no `taina.conf`, e o
`127.0.0.1:4000` publicado só no loopback (é o que o `tailscale serve` usa).

## NixOS

O `services.taina` roda o Tainá como serviço systemd, sem container, e põe a CLI
no PATH:

```nix
{
  inputs.oka.url = "github:taina-labs/oka";
  # ...
  services.taina = {
    enable = true;
    hostname = "nuvem.suacomunidade.org";
  };
}
```

No NixOS, instalação, configuração e atualização pertencem ao módulo
`services.taina` e são aplicadas com `sudo nixos-rebuild switch`. `taina setup`
retorna uma orientação em vez de fingir que configurou o serviço. A CLI continua
servindo para `status`, `logs`, `restart`, `backup`, `restore` e `doctor`.

## Guias do operador

Documentação completa no repositório [Tekoá](https://github.com/taina-labs/tekoa).
Para começar, o
[guia de instalação](https://github.com/taina-labs/tekoa/blob/main/guias/instalacao.md):

- [Acesso remoto](https://github.com/taina-labs/tekoa/blob/main/guias/acesso-remoto.md)
  (Tailscale recomendado, Headscale soberano, WireGuard avançado).
- [Runbook de backup e restauração](https://github.com/taina-labs/tekoa/blob/main/guias/runbook-backup-restore.md)
  (procedimento e ensaio).
- [Hardware e montagem](https://github.com/taina-labs/tekoa/blob/main/guias/compras-hardware.md).

## Licença

[GNU Affero General Public License v3.0](LICENSE), a mesma do Tainá.
