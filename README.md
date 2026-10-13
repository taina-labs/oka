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

# sobe o Tainá
taina setup
```

O `setup` gera o segredo em `taina.conf`, cria a rede, sobe o container do Tainá
(a imagem `ghcr.io/taina-labs/taina`) e imprime o endereço do assistente de
configuração. Sem domínio, use `taina setup --domain nuvem.suacomunidade.org`
para o `PHX_HOST` das URLs.

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
taina setup [--domain D]     instala e sobe o Taina
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
`TAINA_DOMAIN`, `TAINA_DB_DIR`, `TAINA_STORAGE_DIR`, `TAINA_BACKUP_DIR` (vazios
usam volumes nomeados), `SECRET_KEY_BASE`.

## Atualização

```sh
taina update
```

Baixa a imagem nova, guarda uma cópia do banco em `rollback/`, recria o
container e confere a saúde. As migrações rodam sozinhas no boot.

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

No NixOS o update é `nixos-rebuild switch`; a CLI continua servindo para
`status`, `logs`, `restart`, `backup`, `restore` e `doctor`.

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
