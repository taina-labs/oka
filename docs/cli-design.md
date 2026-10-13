# CLI do operador (`taina`)

Design da CLI que substitui o `install.sh` e o `update.sh` do Oka. É a
interface do zelador com uma caixa: hoje uma caixa Docker, e no NixOS uma
camada fina sobre o `systemd` para manter a mesma API.

## Objetivos

- Um comando só para operar a caixa: instalar, subir, atualizar, expor, ler
  logs, ver status e saúde, e recuperação administrativa (backup, restore,
  doctor).
- A CLI é a única interface. O operador não digita `docker` nem `systemd` no
  dia a dia.
- Orquestração testável. A dor que motivou isto é o custo de manter shell:
  bash-isms, quoting, e a peça que quebra a cada mudança de deploy.

## Não-objetivos

- Gerenciar uma release "bare" buildada à mão: os verbos de domínio são do
  release. Quem roda bare chama `bin/taina <verbo>` direto, sem CLI.
- Frota de caixas, multi-Tekoa, Windows, e uma UI de configuração.

## Decisões

1. Zig, binário único, chamado `taina`. Mesmo padrão do pesque: CLI no host,
   `/app/bin/taina` no release.
2. Docker puro, sem compose. Um backend `systemd` mínimo existe só para a API
   continuar unificada no NixOS.
3. `update` é explícito, nunca automático.
4. Caddy como sidecar opcional: a base sobe só o app; `expose` (com um domínio)
   adiciona o Caddy na mesma rede.
5. O release expõe `bin/taina <verbo>`; a CLI faz forward do verbo de domínio e
   lê só o exit code (não parseia stdout).
6. A CLI mora no `oka`. O `taina` (a aplicação) mantém o build.

## Layout (oka)

```
oka/
  cli/                  # a CLI, em Zig
    build.zig
    src/main.zig        # parse de argumentos, dispatch, uso
    src/verbs.zig       # a tabela de verbos abaixo
    src/driver.zig      # a interface de driver e a deteccao
    src/drivers/docker.zig
    src/drivers/systemd.zig
    src/proc.zig        # rodar comandos, capturar, exit codes
    src/detect.zig      # deteccao de backend e leitura do ambiente
    src/prompt.zig      # prompts sem eco (segredos)
    src/config.zig      # leitura e escrita do taina.conf
  deploy/
    Caddyfile
    Caddyfile.local
  nix/
    flake.nix           # inputs.taina, packages.taina (CLI), nixosModules.taina
    module.nix          # services.taina (modo systemd e modo docker)
  docs/
    cli-design.md       # este documento
  README.md
```

## Verbos

Backend (unificados entre docker e systemd):

| Verbo | docker | systemd |
| --- | --- | --- |
| `status` | estado do container | `systemctl is-active taina` |
| `logs [-f] [--tail N]` | `docker logs` | `journalctl -u taina` |
| `restart` | recria o app | `systemctl restart taina` |
| `health` | sonda `/health` | sonda `/health` |
| `backend` | imprime backend, capacidades e caminhos | idem |

Ciclo de vida (só docker; no systemd, no-op com mensagem):

| Verbo | Efeito |
| --- | --- |
| `setup [--domain D]` | gera segredo, escreve o `taina.conf`, cria rede e sobe o app (e o Caddy, se houver domínio) |
| `up` / `down` | sobe / para (dados preservados) |
| `expose --domain D` | adiciona o Caddy com o domínio |
| `unexpose` | remove o Caddy |

Atualização (explícito nos dois):

| Verbo | docker | systemd |
| --- | --- | --- |
| `update [--tag T]` | `docker pull` do app, recria, checa saúde, guarda o rollback | imprime o `nixos-rebuild switch` (não roda sozinho) |

Domínio (forward pro release, sempre):

| Verbo | Efeito |
| --- | --- |
| `backup [--out DIR]` | `Taina.Nhaman.Backup.run/1` |
| `restore <arquivo.tar.gz>` | `Taina.Nhaman.Backup.restore/2` |
| `doctor` | diagnóstico da caixa |
| `version` | versão da CLI e da release |

Globais: `--backend docker|systemd`, `--config PATH`, `--yes`, `--version`.

Exit codes congelados (iguais aos do pesque): `0` ok, `1` falha de domínio,
`2` uso incorreto, `3` falha de driver ou ambiente.

## Driver docker

- Config: um `taina.conf` (chave=valor) com `TAINA_DOMAIN`, `TAINA_IMAGE`,
  `TAINA_DB_DIR`, `TAINA_STORAGE_DIR`, `TAINA_BACKUP_DIR`, `SECRET_KEY_BASE`,
  `TAINA_UPDATE_CHECK`. O `setup` gera o que falta.
- `setup`: cria a rede `taina`; sobe `taina-app` (imagem, env, os três volumes
  de dados, `127.0.0.1:4000`, `restart=unless-stopped`, caps de log,
  healthcheck). Com domínio, sobe `taina-caddy` na mesma rede (portas 80/443,
  Caddyfile montado).
- Forward: `docker exec taina-app /app/bin/taina <verbo>`.
- `update`: `docker pull`, recria o app (e o Caddy, se houver), checa a saúde, e
  guarda o rollback (a cópia do arquivo do banco, como o `update.sh` faz hoje).
- Todo comando externo passa pelo `proc.zig`; nada de `sh -c`.

## Driver systemd

Mínimo, para a API não mudar:

- `status`: `systemctl is-active taina`, mais os caminhos (release, unit, conf).
- `logs`: `journalctl -u taina [-f]`.
- `restart`: `systemctl restart taina`.
- `health`: sonda `http://127.0.0.1:4000/health`.
- Domínio: `bin/taina <verbo>` no caminho do release (o módulo exporta
  `TAINA_RELEASE`).
- `setup`/`up`/`down`/`expose`: no-op com mensagem ("no NixOS, o módulo é dono").
- `update`: imprime o `nixos-rebuild switch --flake ...`.

Detecção: `--backend`, senão `TAINA_BACKEND`, senão heurística (existe a unit
`taina.service` com `systemctl` -> systemd; existe `docker` -> docker).

## Contrato do release

O release ganha um ponto de entrada de verbos, no mesmo molde do
`/app/bin/pesque <verbo>` do pesque:

- `Taina.CLI.main/1` recebe `[verbo | args]` e roda o verbo de domínio.
- Executado pelo release (`bin/taina`), direto ou via `eval`, e a CLI faz
  `docker exec taina-app /app/bin/taina <verbo>`.
- O release não loga para parse; só o exit code importa.

Hoje o release expõe `bin/taina eval` e `bin/taina start`. Este contrato
adiciona os verbos de domínio (`backup`, `restore`, `doctor`, `version`). É do
lado do `taina` (Elixir), não da CLI.

## Nix (oka)

- `flake.nix`: `inputs.taina = github:taina-labs/taina` (e
  `inputs.taina.inputs.nixpkgs.follows = "nixpkgs"`), mais
  `packages.taina` (a CLI, via o setup hook do Zig do nixpkgs) e
  `nixosModules.taina`.
- `module.nix`: `services.taina.mode = "systemd" | "docker"`, default
  `systemd`.
  - `systemd`: como hoje, a release buildada pelo Nix (`inputs.taina`),
    `DATABASE_PATH`, os diretórios de dados, `ExecStartPre` migrate, hardening.
    Sem Docker na caixa. O proxy é do host (o módulo não sobe proxy).
  - `docker`: `virtualisation.oci-containers` puxando a imagem do ghcr, com
    volumes, env e portas. Mesma regra de proxy: quem expõe é o host.
  - Em ambos, a CLI entra em `environment.systemPackages` com
    `TAINA_BACKEND=systemd` no ambiente.
- O módulo **não** builda imagem: o `Dockerfile` do `taina` continua sendo a
  fonte canônica, publicada no ghcr pelo CI, e o modo docker puxa de lá.

## O que sai e o que fica

- `taina` (a aplicação): fica o código, os testes, o `Dockerfile` (imagem
  canônica, ghcr), o `nix/package.nix` (a release) e o CI (testes, docker-smoke,
  release-please com o publish da imagem). Sai o `nix/module.nix` (vai pro oka)
  e o `docker-compose.yml` de dev (dev é `mix`, com o arquivo SQLite).
- `oka`: saem `install.sh`, `update.sh` e `docker-compose.yml`. Ficam o
  Caddyfile, os guias (reescritos em volta da CLI) e entram a CLI, o `flake.nix`
  e o `module.nix`.
- A dependência é sempre `oka -> taina` (input), nunca o contrário.

## Rollout

1. CLI com o driver docker: `setup`, `up`, `down`, `expose`, `logs`, `status`,
   `health`, `update`, e o forward de domínio.
2. Contrato `bin/taina <verbo>` no release do `taina`.
3. Driver systemd e o `module.nix` nos dois modos.
4. Guias (oka README e tekoa) reescritos em volta da CLI.
5. Apagar os scripts de shell e o compose.

Até o passo 5, o `install.sh`/`update.sh` continuam valendo, então a CLI nasce
em paralelo e o corte é no fim.
