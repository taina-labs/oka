# Oka

Oka is the deployment bundle for [Taina](https://github.com/taina-labs/taina).
It contains the Compose operator adapter and re-exports Taina's NixOS module.

## Compose

The normal deployment does not require the Taina source tree:

```sh
cd deploy/compose
./taina init
$EDITOR taina.conf
docker compose up --detach --wait
```

The service is named `taina`, publishes `127.0.0.1:4000`, and stores state in
the named Docker volumes `taina-data` and `taina-storage`. Backups go to the
host directory bound to `/app/backups`: the `source:` of that bind in
`compose.yaml`, `./backups` by default, which must already exist. Point it at a
separate disk or mount for disaster recovery; a backup on the same filesystem as
the data volume only survives mistakes, not a disk loss. The image tag is pinned
in `compose.yaml`. Put Caddy, Tailscale Serve, or another TLS proxy in front;
`deploy/Caddyfile` and `deploy/Caddyfile.local` are examples.

Compose owns lifecycle. Use `docker compose stop`, `restart`, `ps`, `logs`, and
`pull` directly. The adapter forwards release domain commands:

```sh
./taina doctor
./taina config validate
./taina backup
./taina account reset-password USERNAME
./taina thumbnails regenerate
```

Restore is deliberately cold and never stops or starts the service itself:

```sh
docker compose stop taina
./taina restore ARCHIVE_NAME
docker compose up --detach --wait
```

`taina.conf` is a strict, non-secret configuration file. The release creates
its persistent secret under the configured data directory on first boot.

### Rootless Docker

Under [rootless Docker](https://docs.docker.com/engine/security/rootless/) your
user is mapped to container uid 0 and every other user to a subuid, so the host
bind mounts are reachable only by container root. Run the service as that uid by
adding `user: "0"` to the `taina` service in `compose.yaml`; otherwise the
scheduled backup cannot write `./backups` and fails silently. `./taina` already
runs the commands that touch the backup directory (`backup`, `restore`,
`doctor`) as root for the same reason. The backup directory must stay owned by
your user; if an earlier run left it under a subuid, reclaim it:

```sh
sudo chown -R "$(id -u):$(id -g)" backups
```

For local image development, `./build-image.sh` builds an image from a Taina
checkout. The default `deploy/compose/smoke.sh` check is static only. To run
the Docker integration smoke test with a locally built image, set
`TAINA_SMOKE_IMAGE`, for example `TAINA_SMOKE_IMAGE=taina:local deploy/compose/smoke.sh`.

## NixOS

Import either module exposed by this flake. The implementation and its options
are owned by Taina, and NixOS runs the same pinned OCI image as Compose:

```nix
inputs.oka.url = "github:taina-labs/oka";

services.taina = {
  enable = true;
  image = "ghcr.io/taina-labs/taina:v0.7.0";
  hostname = "community.example.org";
};
```

Systemd owns lifecycle on NixOS. Use the configured `taina` command only for
domain operations and `systemctl` or `journalctl` for service operations.
