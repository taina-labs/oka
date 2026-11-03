# Replace the Zig CLI with release verbs and shell adapters

Status: proposed

## Context

Oka currently contains a Zig operator CLI, a NixOS module, Caddy examples and
an image build helper. The Zig CLI owns the Docker container directly: it
creates the network, volumes, environment, health checks and update flow.
There is no Compose deployment bundle in Oka yet.

Taina already has the start of a release-side operator API in
`lib/taina/cli.ex`, with `backup`, `restore`, `doctor` and `version`. It also
has operational logic trapped in Mix tasks for password recovery and thumbnail
regeneration.

Pesque provides the target shape:

- release verbs run through `bin/cli`;
- Compose and systemd own lifecycle;
- small POSIX shell adapters forward operator commands and enforce cold
  restore;
- application settings live in a typed, strict `.conf` file;
- Compose and NixOS run the same pinned OCI image.

Taina is in alpha. There are no production installations to preserve. This is
an intentional breaking change: old containers, old CLI configuration, the Nix
release package and previous deployment commands can all be dropped. No legacy
migration or compatibility runbook is required.

## Goals

- Delete the Zig CLI and its build, release and maintenance machinery.
- Make web onboarding the only product setup flow.
- Make Docker Compose own Docker lifecycle.
- Make systemd own NixOS lifecycle.
- Expose operational domain work as verbs in the Taina release.
- Keep host adapters small and free of domain logic.
- Use one strict `taina.conf` format for application settings.
- Run the same pinned OCI image in Compose and NixOS.
- Keep the canonical NixOS module in Taina and re-export it from Oka.

## Non-goals

- No standalone operator binary to install.
- No shell API for onboarding, invitations, roles or other social operations.
- No automatic lifecycle management inside release verbs.
- No compatibility with the Zig configuration or containers.
- No arbitrary database rollback command.
- No generic `.env` file as the public configuration interface.

## Repository boundaries

### Oka

Oka is the deployment repository. Operators can clone it without cloning the
Taina source tree.

```text
oka/
  deploy/
    compose/
      compose.yaml
      taina
      taina.conf.example
      smoke.sh
    Caddyfile
    Caddyfile.local
  docs/
    shell-operator-migration.md
  build-image.sh
  flake.nix
```

The Compose host adapter owns only:

- `init`: create `taina.conf` from the example and create the local backup
  directory without overwriting existing files. Compose named volumes own the
  application data and storage paths;
- path adaptation for backup and restore;
- the cold-restore precondition;
- forwarding domain commands to `/app/bin/cli` in a one-off container.

Compose owns `up`, `stop`, `restart`, `ps`, `logs`, image pulls and updates.
The wrapper must not recreate those commands.

There is no need to copy Pesque's `docker/healthcheck.sh`: the Taina image
already contains `curl`, so Compose can declare the health check inline.

`build-image.sh` remains an optional development helper. The normal deployment
uses the published image and does not download the Taina source tree.

### Taina

Taina owns the application, its image, its release entrypoints, its
configuration contract and its NixOS module.

```text
taina/
  Dockerfile
  taina.conf.example
  rel/overlays/bin/
    server
    cli
  lib/taina/cli.ex
  lib/taina/config.ex
  nix/
    module.nix
    operator.sh
    module-check.nix
```

`bin/cli` is a thin POSIX wrapper around `Taina.CLI` and the generated release
script. It replaces shell code that constructs quoted `eval` expressions.

`bin/server` prepares persistent state, runs migrations and starts Phoenix.
The Dockerfile and NixOS both invoke this same entrypoint. Migration logic must
not remain split between Docker's `CMD` and NixOS `ExecStartPre`.

The old root `docker-compose.yml`, the Nix release package and the Oka Zig
implementation can be removed. Development from source uses Mix directly.

## Configuration: `taina.conf`

A real configuration file is a better public interface than a generic `.env`
file for this deployment model. It gives Taina one typed configuration
contract, works identically in the release and one-off operator commands, and
can be mounted read-only. It also lets NixOS generate the same file from typed
module options.

The parser is deliberately small:

- one `key = value` entry per line;
- blank lines and `#` comments;
- no shell evaluation, interpolation or quoting language;
- unknown keys fail boot;
- duplicate keys fail boot;
- invalid values report the key and line number;
- parsing and validation happen at the configuration boundary.

`Taina.Config` implements `Config.Provider`. `TAINA_CONFIG` selects the file;
it does not override individual settings. There should not be a parallel set
of public environment variables that silently changes the same settings.

Initial keys:

```ini
# Public URL used in generated links, after TLS termination.
url_scheme = https
hostname = community.example.org
url_port = 443

# HTTP listener inside the container.
bind_ip = 0.0.0.0
port = 4000

# Persistent application paths.
data_dir = /app/data
storage_dir = /app/storage
backup_dir = /app/backups

backup_enabled = true
update_check = false

# Optional. Defaults to DATA_DIR/secret_key_base.
# secret_key_base_file = /app/data/secret_key_base
```

The SQLite database is `DATA_DIR/taina.db`; a second database path setting is
unnecessary for the supported deployment.

### Listener and public URL are different settings

`port` and `bind_ip` describe the HTTP listener. They do not describe the
public origin.

`url_scheme`, `hostname` and `url_port` describe links generated by Phoenix.
`url_port` defaults to 443 for HTTPS and 80 for HTTP. Keeping it explicit avoids
Pesque's hostname-based inference, which Taina does not need.

For containers, `bind_ip` normally remains `0.0.0.0`. Host exposure is controlled
by the Compose or NixOS port publication, not by changing the container's
listener to a host-specific address.

### Secrets are not configuration values

`taina.conf` contains no secret material. In particular, it does not contain
`SECRET_KEY_BASE` and does not accept passwords.

The release creates `secret_key_base_file` on first preparation when it does
not exist, using mode `0600`, and reuses it afterward. The default is
`DATA_DIR/secret_key_base`. Application startup reads the file and installs
the endpoint secret before the endpoint starts, following Pesque's persistent
secret pattern.

The configuration file exists before secret generation. `./taina init` writes
`taina.conf` without creating secrets. On the first server boot, the config
provider reads that file, then `bin/server` prepares the data directories and
secret before running migrations or starting the endpoint. This is Pesque's
actual order. The secret must exist before database preparation and Phoenix,
not before `taina.conf`: its default location is derived from `data_dir`, so
generating it earlier would make the host adapter guess configuration it does
not own.

This removes the generic secret `.env` file from both deployment paths. An
external secret file remains possible by changing `secret_key_base_file`.
Backups must include this file so a restored instance has all required server
state.

Add these configuration verbs:

```text
taina config validate
taina config template [--out PATH]
```

`validate` resolves exactly what boot will resolve and prints non-secret
settings. `template` emits the short example. The example committed in Oka is
synchronized from Taina by the version-update workflow and exercised by the
Compose smoke test.

## Release operator API

The release surface is intentionally small:

```text
taina backup [--out DIR]
taina restore ARCHIVE
taina doctor
taina version
taina config validate
taina config template [--out PATH]
taina account reset-password USERNAME
taina thumbnails regenerate
```

Every command supports `--help`. Exit codes remain stable: 0 for success, 1
for a domain failure, 2 for usage and 3 for an environment failure.

`account reset-password` moves the existing `mix taina.senha` logic into an
application module available in the release. The new password comes from a
no-echo prompt or stdin, never argv or the environment. Device revocation and
pending reset-token invalidation remain part of the domain operation.

`thumbnails regenerate` moves the existing Mix task logic into an application
module. The Mix task can remain as a development adapter over the same code.

Do not add:

- `setup`: onboarding belongs to the web interface;
- `up`, `down`, `restart`, `logs`, `status` or `update`: lifecycle belongs to
  Compose or systemd;
- account creation, invitations or role changes: these are governed product
  operations, not unrestricted shell operations;
- `migrate`: normal migration belongs to `bin/server`;
- `rollback`: no supported operator use case justifies it;
- `backup verify`: the existing destructive round trip belongs to CI.

## Compose behavior

The deployment uses a pinned image, never `latest`:

```sh
./taina init
$EDITOR taina.conf
docker compose up --detach --wait
```

The Compose service is named `taina`. It sets `TAINA_CONFIG=/app/taina.conf`
and mounts the bundle's `taina.conf` read-only at that path. `/app/data` and
`/app/storage` use named Docker volumes so Docker can seed the image's runtime
ownership; only `/app/backups` is a host-visible bind mount.

Lifecycle remains direct Compose usage:

```sh
docker compose up --detach --wait
docker compose stop taina
docker compose restart taina
docker compose ps
docker compose logs -f taina
```

Updates are manual:

```sh
./taina backup
docker compose pull
docker compose up --detach --wait
```

Domain commands run in one-off containers with the same image, configuration
and mounts:

```sh
./taina doctor
./taina config validate
./taina backup
./taina account reset-password maria
./taina thumbnails regenerate
```

Restore is cold. The adapter refuses to run it while the service exists in a
running state and prints the required Compose stop command. It does not stop
or restart the service itself:

```sh
docker compose stop taina
./taina restore ARCHIVE_NAME
docker compose up --detach --wait
```

The Compose file publishes the internal listener on `127.0.0.1` by default.
Caddy, Tailscale Serve or another proxy owns TLS. Keep both Caddy examples:
the public-domain configuration and the optional local-CA configuration for
local-only deployments. These examples belong only to the Compose deployment;
the NixOS module does not import them or configure Caddy. Backup archives are
written to a host-visible backup directory.

The checked-in `smoke.sh` performs static bundle checks by default. An operator
can set `TAINA_SMOKE_IMAGE` to a locally built image to opt into the Docker
boot, backup, and cold-restore integration smoke test.

## NixOS module

The canonical module moves to `taina/nix/module.nix`. Oka only re-exports
`taina.nixosModules.taina` and `taina.nixosModules.default`; it does not keep a
second implementation.

The module follows Pesque's shape and runs the same pinned OCI image as
Compose. This removes the separate Nix-built release, its fixed-output Mix
dependency hash and the possibility of Docker and NixOS running different
native dependency sets.

Module responsibilities:

- generate `taina.conf` from typed options;
- map host state directories to fixed container paths;
- declare explicit UID and GID ownership;
- publish the container port on `listenAddress`;
- enforce `requiredMounts` before service and one-off commands;
- install a configured `taina` shell command;
- run lifecycle through systemd;
- provide a backup oneshot suitable for timers.

`settings` accepts uncommon application keys verbatim but rejects every key
owned by a typed module option. The image must select an explicit tag or
digest; `latest` is refused.

The generated `nix/operator.sh` forwards domain commands to one-off containers
using the same image, configuration and mounts. It enforces cold restore and
does not reimplement release logic. Lifecycle remains `systemctl` and
`journalctl`.

### Example based on `hosts/yby/configuration.nix`

The current personal configuration is a good fit for separate ZFS datasets,
but two details should improve:

- replace `bindIp = "0.0.0.0"` with a host-side `listenAddress` restricted to
  the tailnet address when the proxy reaches Taina through Tailscale;
- use a Taina-specific backup directory rather than sharing the parent with
  unrelated service backups.

The session environment file is no longer needed because the release owns its
persistent secret file. Firewall policy remains explicit and tailnet-only;
there is no need for a module option that opens the port on every interface.

```nix
services.taina = {
  enable = true;
  image = "ghcr.io/taina-labs/taina:v0.6.1";

  scheme = "https";
  hostname = "solaria.taina.dev.br";
  urlPort = 443;

  port = 4014;
  listenAddress = "100.64.0.2";

  uid = 993;
  gid = 993;

  dataDir = "/zdata/taina";
  storageDir = "/zdata/ybira";
  backupDir = "/zdata/backups/taina";
  requiredMounts = [
    "/zdata/taina"
    "/zdata/ybira"
    "/zdata/backups"
  ];

  backup.enable = true;
  updateCheck = false;
};

networking.firewall.interfaces.tailscale0.allowedTCPPorts = [4014];
```

Inside the generated container configuration, the paths are `/app/data`,
`/app/storage` and `/app/backups`, matching the Compose deployment and the
image. The host paths above are mounts, not application-level path settings.

## Removals and breaking changes

Delete from Oka:

- `cli/`;
- `nix/cli.nix` and the local module implementation;
- Zig inputs, packages and dev-shell tooling from `flake.nix`;
- Zig CI and cross-compiled release artifacts;
- release-please metadata for `cli/build.zig.zon`;
- documentation for the old CLI, `.env` configuration and container lifecycle.

Delete from Taina:

- the production-looking root Compose file;
- the Nix release package when the OCI-based module is working;
- environment-based deployment configuration replaced by `taina.conf`;
- Docker- and NixOS-specific boot migration wrappers replaced by `bin/server`.

Keep development Mix tasks only where they provide a useful development
adapter over release-safe application logic.

## Implementation order

1. Add `Taina.Config`, strict parsing, `config validate` and `config template`.
2. Add persistent secret preparation and include the secret in backup/restore.
3. Add release `bin/cli`, unify boot in `bin/server`, and move the two useful
   Mix task operations into release-safe application modules.
4. Add the Oka Compose bundle and host adapter.
5. Move the NixOS module to Taina, switch it to the pinned OCI image and add
   its configured shell adapter and module checks.
6. Re-export the module from Oka and update the version-pinning workflow to
   update both the flake input and Compose image.
7. Run release tests, configuration parser tests, shell syntax checks,
   ShellCheck, Compose smoke tests and NixOS module checks.
8. Replace the documentation, then delete the Zig CLI and obsolete release
   machinery.

The Zig directory is removed only after the new release and both host adapters
pass their smoke tests. No instance migration runbook is needed.
