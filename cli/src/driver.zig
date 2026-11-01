//! The driver: a tagged union over the closed backend set (docker, systemd).
//! docker owns the container (the CLI runs it); systemd is a thin read/ops
//! layer over the NixOS module's unit.
const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");
const config = @import("config.zig");

const Error = proc.Error;

pub const Kind = enum { docker, systemd };

/// A domain verb, run inside the release and forwarded from here.
pub const RunOnce = struct {
    verb: []const u8,
    argv: []const []const u8 = &.{},
};

pub const LogOpts = struct {
    follow: bool = false,
    tail: ?u64 = null,
};

pub const Health = enum { healthy, degraded };

pub const Docker = struct {
    container: []const u8 = "taina-app",
    network: []const u8 = "taina",
    image: []const u8 = "",
};

pub const Systemd = struct {
    unit: []const u8 = "taina",
    release: []const u8 = "",
};

pub const Driver = union(Kind) {
    docker: Docker,
    systemd: Systemd,

    pub fn kind(self: Driver) Kind {
        return switch (self) {
            .docker => .docker,
            .systemd => .systemd,
        };
    }

    pub fn setup(self: Driver, host: *proc.Host, cfg: *const config.Config) Error!u8 {
        return switch (self) {
            .docker => dockerSetup(host, cfg),
            .systemd => systemdSetup(host),
        };
    }

    pub fn up(self: Driver, host: *proc.Host) Error!u8 {
        return switch (self) {
            .docker => |d| dockerSimple(host, "subindo o Taina", &.{ host.progs.docker, "start", d.container }),
            .systemd => noopLifecycle(host, "up"),
        };
    }

    pub fn down(self: Driver, host: *proc.Host) Error!u8 {
        return switch (self) {
            .docker => |d| dockerSimple(host, "parando o Taina (os dados ficam)", &.{ host.progs.docker, "stop", d.container }),
            .systemd => noopLifecycle(host, "down"),
        };
    }

    pub fn restart(self: Driver, host: *proc.Host) Error!u8 {
        return switch (self) {
            .docker => |d| dockerSimple(host, "reiniciando o Taina", &.{ host.progs.docker, "restart", d.container }),
            .systemd => |d| systemdSimple(host, "reiniciando o Taina", &.{ host.progs.systemctl, "restart", d.unit }),
        };
    }

    pub fn logs(self: Driver, host: *proc.Host, opts: LogOpts) Error!u8 {
        return switch (self) {
            .docker => |d| dockerLogs(host, d, opts),
            .systemd => |d| systemdLogs(host, d, opts),
        };
    }

    pub fn health(self: Driver, host: *proc.Host, cfg: *const config.Config) Error!Health {
        return switch (self) {
            .docker => |d| dockerHealth(host, d),
            .systemd => systemdHealth(host, cfg),
        };
    }

    pub fn status(self: Driver, host: *proc.Host) Error!u8 {
        return switch (self) {
            .docker => |d| dockerStatus(host, d),
            .systemd => |d| systemdStatus(host, d),
        };
    }

    pub fn update(self: Driver, host: *proc.Host, cfg: *const config.Config, tag: ?[]const u8) Error!u8 {
        return switch (self) {
            .docker => dockerUpdate(host, cfg, tag),
            .systemd => systemdUpdate(host),
        };
    }

    pub fn runOnce(self: Driver, host: *proc.Host, ro: RunOnce) Error!u8 {
        return switch (self) {
            .docker => |d| dockerRunOnce(host, d, ro),
            .systemd => |d| systemdRunOnce(host, d, ro),
        };
    }

    /// restore is not a plain forward: it replaces the database file, so the
    /// app has to be stopped first and the verb runs in a one-off.
    pub fn restore(self: Driver, host: *proc.Host, argv: []const []const u8) Error!u8 {
        return switch (self) {
            .docker => |d| dockerRestore(host, d, argv),
            .systemd => |d| systemdRestore(host, d, argv),
        };
    }

    pub fn describe(self: Driver, host: *proc.Host, cfg: *const config.Config) Error!u8 {
        return switch (self) {
            .docker => |d| dockerDescribe(host, d, cfg),
            .systemd => |d| systemdDescribe(host, d),
        };
    }
};

// --- docker ------------------------------------------------------------------

/// A fresh named volume, and a host dir the operator pointed at, can be
/// root-owned; make the app's data roots writable by the runtime user
/// (nobody, 65534) before the run.
fn ensureDataPerms(host: *proc.Host, cfg: *const config.Config) Error!void {
    var argv: std.ArrayList([]const u8) = .empty;
    const g = host.gpa;
    defer argv.deinit(g);
    try argv.appendSlice(g, &.{ host.progs.docker, "run", "--rm", "--user", "root", "--entrypoint", "/bin/sh" });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.db_dir, "taina_db", "/app/data") });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.storage_dir, "taina_storage", "/app/storage") });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.backup_dir, "taina_backups", "/app/backups") });
    try argv.append(g, cfg.image);
    try argv.appendSlice(g, &.{ "-c", "chown 65534:65534 /app/data /app/storage /app/backups" });
    const code = host.run(argv.items) catch |e| {
        host.err("nao consegui ajustar as permissoes dos dados. Confira o Docker e a imagem {s} antes de tentar novamente.", .{cfg.image});
        return e;
    };
    if (code != 0) {
        host.err("nao consegui ajustar as permissoes do banco, storage e backups. Verifique a imagem {s} e tente 'taina setup' novamente.", .{cfg.image});
        return error.DriverFailed;
    }
}

fn dockerSetup(host: *proc.Host, cfg: *const config.Config) Error!u8 {
    var mutable = cfg.*;
    if (mutable.secret.len == 0) {
        mutable.secret = try generateSecret(host);
        if (mutable.file_exists) {
            try config.persistSecret(host, &mutable);
        } else {
            try config.createInitial(host, &mutable);
        }
    } else if (!mutable.file_exists) {
        try config.createInitial(host, &mutable);
    }

    try ensureNetwork(host, mutable.network);
    var current_container = mutable.container;
    var exists = try containerExists(host, current_container);
    if (!exists) {
        if (try managedContainer(host)) |previous| {
            current_container = previous;
            exists = true;
        }
    }
    if (exists) {
        const matches = try containerMatches(host, &mutable, current_container);
        const status = try containerStatus(host, current_container);
        if (matches) {
            if (std.mem.eql(u8, status, "running")) {
                host.step("validando a saude do Taina ja configurado", .{});
                try finishSetup(host, &mutable, "O Taina ja esta configurado e saudavel.");
                return 0;
            }
            host.step("iniciando o container parado", .{});
            const start_code = host.run(&.{ host.progs.docker, "start", current_container }) catch |e| {
                host.err("nao consegui iniciar o container '{s}'. Os dados continuam preservados; tente 'taina setup' novamente.", .{current_container});
                return e;
            };
            if (start_code != 0) {
                host.err("o container '{s}' continua parado. Os dados estao preservados; confira 'taina logs' e tente 'taina setup' novamente.", .{current_container});
                return start_code;
            }
            try finishSetup(host, &mutable, "O Taina foi iniciado e esta saudavel.");
            return 0;
        }

        host.step("a configuracao mudou; recriando apenas o container", .{});
        try ensureDataPerms(host, &mutable);
        if (!std.mem.eql(u8, status, "exited") and !std.mem.eql(u8, status, "created") and !std.mem.eql(u8, status, "dead")) {
            const stop_code = host.run(&.{ host.progs.docker, "stop", current_container }) catch |e| {
                host.err("nao consegui parar o container '{s}'. Ele pode continuar rodando com a configuracao anterior; os dados foram mantidos.", .{current_container});
                return e;
            };
            if (stop_code != 0) {
                host.err("nao consegui parar o container '{s}'. Ele pode continuar rodando com a configuracao anterior; os dados foram mantidos.", .{current_container});
                return stop_code;
            }
        }
        const rm_code = host.run(&.{ host.progs.docker, "rm", current_container }) catch |e| {
            host.err("nao consegui remover o container antigo '{s}'. Nenhum volume foi removido; tente 'taina setup' novamente.", .{current_container});
            return e;
        };
        if (rm_code != 0) {
            host.err("nao consegui remover o container antigo '{s}'. Nenhum volume foi removido; tente 'taina setup' novamente.", .{current_container});
            return rm_code;
        }
        return createContainer(host, &mutable, "O Taina foi reconfigurado e esta saudavel.");
    }

    try ensureDataPerms(host, &mutable);
    return createContainer(host, &mutable, "O Taina foi configurado e esta saudavel.");
}

fn createContainer(host: *proc.Host, cfg: *const config.Config, success_message: []const u8) Error!u8 {
    host.step("subindo o Taina", .{});
    const dir = host.makeTempDir() catch |e| {
        reportContainerCreateFailure(host, cfg);
        return e;
    };
    defer host.removeTempDir(dir);
    const env_file = writeContainerEnv(host, cfg, dir) catch |e| {
        reportContainerCreateFailure(host, cfg);
        return e;
    };
    const fingerprint = configFingerprint(host, cfg) catch |e| {
        reportContainerCreateFailure(host, cfg);
        return e;
    };
    const argv = runArgs(host, cfg, env_file, fingerprint) catch |e| {
        reportContainerCreateFailure(host, cfg);
        return e;
    };
    const code = host.run(argv) catch |e| {
        reportContainerCreateFailure(host, cfg);
        return e;
    };
    if (code != 0) {
        reportContainerCreateFailure(host, cfg);
        return code;
    }
    try finishSetup(host, cfg, success_message);
    return 0;
}

fn reportContainerCreateFailure(host: *proc.Host, cfg: *const config.Config) void {
    host.err("nao consegui criar o container '{s}'. A caixa pode ficar sem container ativo; os volumes e diretorios de dados foram preservados. Corrija o erro e rode 'taina setup' novamente.", .{cfg.container});
}

fn finishSetup(host: *proc.Host, cfg: *const config.Config, success_message: []const u8) Error!void {
    host.step("esperando o Taina subir (no primeiro boot pode levar um minuto)", .{});
    if (!try waitHealthy(host, cfg)) {
        host.err("o Taina nao ficou saudavel a tempo. O container continua presente e os dados foram preservados. Veja 'taina logs' e tente 'taina setup' novamente.", .{});
        return error.DriverFailed;
    }
    host.out("{s}", .{success_message});
    printAccess(host, cfg);
}

fn printAccess(host: *proc.Host, cfg: *const config.Config) void {
    host.out("Para configurar o Taina nesta caixa, abra: http://127.0.0.1:{d}/setup", .{cfg.host_port});
    if (cfg.domain.len > 0) {
        host.out("Endereco publico (seu proxy servir HTTPS na porta 443): https://{s}/setup.", .{cfg.domain});
        host.out("Para outra porta publica, acrescente-a a URL. Esse acesso so funciona depois que um proxy ou Tailscale encaminhar para 127.0.0.1:{d}.", .{cfg.host_port});
    } else {
        host.out("Para acesso publico, configure um proxy ou Tailscale Serve com TLS apontando para 127.0.0.1:{d}.", .{cfg.host_port});
    }
}

fn dockerSimple(host: *proc.Host, comptime msg: []const u8, argv: []const []const u8) Error!u8 {
    host.step(msg, .{});
    return host.run(argv);
}

fn dockerLogs(host: *proc.Host, d: Docker, opts: LogOpts) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const g = host.gpa;
    defer argv.deinit(g);
    try argv.appendSlice(g, &.{ host.progs.docker, "logs" });
    if (opts.follow) try argv.append(g, "--follow");
    if (opts.tail) |n| {
        try argv.append(g, "--tail");
        try argv.append(g, try num(host, n));
    }
    try argv.append(g, d.container);
    return host.run(argv.items);
}

fn dockerHealth(host: *proc.Host, d: Docker) Error!Health {
    const argv = [_][]const u8{
        host.progs.docker, "exec", d.container, "curl",
        "-fsS",            "-o",   "/dev/null", "http://localhost:4000/health",
    };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    return if (cap.ok()) .healthy else .degraded;
}

fn dockerStatus(host: *proc.Host, d: Docker) Error!u8 {
    const argv = [_][]const u8{
        host.progs.docker, "inspect", "--format", "{{.State.Status}}", d.container,
    };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("o container '{s}' nao existe. Rode: taina setup", .{d.container});
        return error.DriverFailed;
    }
    host.out("container: {s}", .{cap.line()});
    return 0;
}

fn dockerUpdate(host: *proc.Host, cfg: *const config.Config, tag: ?[]const u8) Error!u8 {
    var mutable = cfg.*;
    if (tag) |t| {
        mutable.image = std.fmt.allocPrint(host.gpa, "ghcr.io/taina-labs/taina:{s}", .{t}) catch return error.OutOfMemory;
    }

    host.step("baixando {s}", .{mutable.image});
    const pull_code = try host.run(&.{ host.progs.docker, "pull", mutable.image });
    if (pull_code != 0) return pull_code;

    // Um desligamento limpo faz o checkpoint do WAL antes da copia do banco.
    if (try containerExists(host, mutable.container)) {
        host.step("guardando o banco em rollback/", .{});
        Io.Dir.cwd().createDirPath(host.io, "rollback") catch {};
        const dest = std.fmt.allocPrint(host.gpa, "rollback/taina-db-{s}.db", .{try randSuffix(host)}) catch return error.OutOfMemory;
        _ = host.run(&.{ host.progs.docker, "stop", mutable.container }) catch {};
        const src = std.fmt.allocPrint(host.gpa, "{s}:/app/data/taina.db", .{mutable.container}) catch return error.OutOfMemory;
        _ = host.run(&.{ host.progs.docker, "cp", src, dest }) catch {};
        _ = host.run(&.{ host.progs.docker, "rm", mutable.container }) catch {};
    }

    try ensureDataPerms(host, &mutable);
    host.step("subindo a versao nova", .{});
    const dir = try host.makeTempDir();
    defer host.removeTempDir(dir);
    const env_file = try writeContainerEnv(host, &mutable, dir);
    const fingerprint = try configFingerprint(host, &mutable);
    const argv = try runArgs(host, &mutable, env_file, fingerprint);
    const code = try host.run(argv);
    if (code != 0) return code;

    if (!try waitHealthy(host, &mutable)) {
        host.err("o Taina nao voltou a ficar saudavel. A copia do banco esta em rollback/ se precisar reverter.", .{});
        return error.DriverFailed;
    }
    host.out("Atualizado.", .{});
    return 0;
}

fn dockerRunOnce(host: *proc.Host, d: Docker, ro: RunOnce) Error!u8 {
    const expr = try evalExpr(host, ro);
    return host.run(&.{ host.progs.docker, "exec", d.container, "/app/bin/taina", "eval", expr });
}

fn dockerRestore(host: *proc.Host, d: Docker, argv: []const []const u8) Error!u8 {
    host.step("parando o Taina (o restore troca o arquivo do banco)", .{});
    const stop_code = try host.run(&.{ host.progs.docker, "stop", d.container });
    if (stop_code != 0) return stop_code;

    const image = try imageOf(host, d);
    const expr = try evalExpr(host, .{ .verb = "restore", .argv = argv });
    const code: u8 = host.run(&.{
        host.progs.docker, "run", "--rm", "--volumes-from", d.container, image, "/app/bin/taina", "eval", expr,
    }) catch {
        _ = host.run(&.{ host.progs.docker, "start", d.container }) catch {};
        return error.DriverFailed;
    };

    host.step("subindo o Taina de novo", .{});
    const start_code = try host.run(&.{ host.progs.docker, "start", d.container });
    if (code != 0) return code;
    return start_code;
}

/// The image the running container was started from, so the restore one-off
/// matches the code the box runs. Falls back to the configured image.
fn imageOf(host: *proc.Host, d: Docker) Error![]const u8 {
    const inspect = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{.Config.Image}}", d.container };
    const cap = try host.capture(&inspect);
    defer host.freeCapture(cap);
    const found = cap.line();
    if (cap.ok() and found.len > 0) return host.gpa.dupe(u8, found) catch error.OutOfMemory;
    if (d.image.len > 0) return d.image;
    host.err("nao consegui descobrir a imagem do container '{s}'. Aponte TAINA_IMAGE.", .{d.container});
    return error.DriverFailed;
}

fn dockerDescribe(host: *proc.Host, d: Docker, cfg: *const config.Config) Error!u8 {
    host.out("backend: docker", .{});
    host.out("container: {s}", .{d.container});
    host.out("network: {s}", .{d.network});
    host.out("image: {s}", .{cfg.image});
    host.out("config: {s}", .{cfg.path});
    return 0;
}

/// The full `docker run` argv for the app container. Used by setup and update.
fn runArgs(host: *proc.Host, cfg: *const config.Config, env_file: []const u8, fingerprint: []const u8) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const g = host.gpa;
    try argv.appendSlice(g, &.{ host.progs.docker, "run", "-d", "--name", cfg.container });
    try argv.appendSlice(g, &.{ "--network", cfg.network, "--restart", "unless-stopped" });
    try argv.appendSlice(g, &.{ "--label", "io.taina.managed=taina" });
    try argv.appendSlice(g, &.{ "--label", try std.fmt.allocPrint(g, "io.taina.config={s}", .{fingerprint}) });
    try argv.appendSlice(g, &.{ "--log-driver", "json-file", "--log-opt", "max-size=10m", "--log-opt", "max-file=3" });
    try argv.appendSlice(g, &.{ "-p", try bindPort(host, cfg.host_port) });
    try argv.appendSlice(g, &.{ "--env-file", env_file });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.db_dir, "taina_db", "/app/data") });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.storage_dir, "taina_storage", "/app/storage") });
    try argv.appendSlice(g, &.{ "-v", try volumeArg(host, cfg.backup_dir, "taina_backups", "/app/backups") });
    try argv.append(g, cfg.image);
    return argv.toOwnedSlice(g) catch error.OutOfMemory;
}

fn volumeArg(host: *proc.Host, dir: []const u8, named: []const u8, target: []const u8) Error![]const u8 {
    const src = if (dir.len > 0) dir else named;
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ src, target }) catch error.OutOfMemory;
}

fn bindPort(host: *proc.Host, port: u16) Error![]const u8 {
    return std.fmt.allocPrint(host.gpa, "127.0.0.1:{d}:4000", .{port}) catch error.OutOfMemory;
}

/// The container environment, written 0600 so the session secret stays off
/// `ps` and off other users' reach.
fn writeContainerEnv(host: *proc.Host, cfg: *const config.Config, dir: []const u8) Error![]const u8 {
    const g = host.gpa;
    const path = std.fs.path.join(g, &.{ dir, "taina.env" }) catch return error.OutOfMemory;
    const body = try containerEnvBody(host, cfg);
    Io.Dir.cwd().writeFile(host.io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    }) catch {
        host.err("nao consegui criar o arquivo temporario de ambiente com permissao privada. Verifique as permissoes do diretorio temporario.", .{});
        return error.DriverFailed;
    };
    return path;
}

fn containerEnvBody(host: *proc.Host, cfg: *const config.Config) Error![]const u8 {
    const g = host.gpa;
    const phx_host = if (cfg.domain.len > 0) cfg.domain else "localhost";
    return std.fmt.allocPrint(g,
        \\DATABASE_PATH=/app/data/taina.db
        \\PHX_HOST={s}
        \\PHX_SERVER=true
        \\PORT=4000
        \\STORAGE_ROOT=/app/storage
        \\BACKUP_ENABLED={s}
        \\BACKUP_DIR=/app/backups
        \\TAINA_UPDATE_CHECK={s}
        \\SECRET_KEY_BASE={s}
        \\
    , .{ phx_host, if (cfg.backup_enabled) "true" else "false", if (cfg.update_check) "true" else "false", cfg.secret }) catch return error.OutOfMemory;
}

fn waitHealthy(host: *proc.Host, cfg: *const config.Config) Error!bool {
    const d = Docker{ .container = cfg.container, .network = cfg.network };
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (try dockerHealth(host, d) == .healthy) return true;
        host.printTo(.stdout, ".", .{});
        host.io.sleep(Io.Duration.fromSeconds(5), .real) catch {
            host.err("a espera pela verificacao de saude foi interrompida.", .{});
            return error.DriverFailed;
        };
    }
    return false;
}

fn containerExists(host: *proc.Host, name: []const u8) Error!bool {
    const argv = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{.Id}}", name };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    return cap.ok();
}

fn managedContainer(host: *proc.Host) Error!?[]const u8 {
    const argv = [_][]const u8{
        host.progs.docker, "ps", "--all", "--filter", "label=io.taina.managed=taina", "--format", "{{.Names}}",
    };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("nao consegui localizar o container anterior do Taina.", .{});
        return error.DriverFailed;
    }
    const found = cap.line();
    if (found.len == 0) return null;
    if (std.mem.indexOfScalar(u8, found, '\n') != null) {
        host.err("encontrei mais de um container gerenciado pelo Taina. Remova os excedentes antes de rodar 'taina setup'.", .{});
        return error.DriverFailed;
    }
    return host.gpa.dupe(u8, found) catch error.OutOfMemory;
}

fn ensureNetwork(host: *proc.Host, network: []const u8) Error!void {
    const argv = [_][]const u8{ host.progs.docker, "network", "create", network };
    const cap = host.capture(&argv) catch |e| {
        host.err("nao consegui verificar/criar a rede Docker '{s}'. Confira o Docker e tente 'taina setup' novamente.", .{network});
        return e;
    };
    defer host.freeCapture(cap);
    if (cap.ok() or std.mem.indexOf(u8, cap.stderr, "already exists") != null) return;
    const detail = std.mem.trim(u8, cap.stderr, " \t\r\n");
    if (detail.len > 0) {
        host.err("nao consegui criar a rede Docker '{s}': {s}. Confira o Docker e tente novamente.", .{ network, detail });
    } else {
        host.err("nao consegui criar a rede Docker '{s}'. Confira o Docker e tente novamente.", .{network});
    }
    return error.DriverFailed;
}

fn containerStatus(host: *proc.Host, name: []const u8) Error![]const u8 {
    const argv = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{.State.Status}}", name };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("nao consegui consultar o estado do container '{s}'.", .{name});
        return error.DriverFailed;
    }
    return host.gpa.dupe(u8, cap.line()) catch error.OutOfMemory;
}

fn containerMatches(host: *proc.Host, cfg: *const config.Config, name: []const u8) Error!bool {
    const managed_format = "{{index .Config.Labels \"io.taina.managed\"}}";
    const managed_argv = [_][]const u8{ host.progs.docker, "inspect", "--format", managed_format, name };
    const managed = try host.capture(&managed_argv);
    defer host.freeCapture(managed);
    if (!managed.ok()) {
        host.err("nao consegui verificar se o container '{s}' pertence ao Taina.", .{name});
        return error.DriverFailed;
    }
    if (!std.mem.eql(u8, managed.line(), "taina") and !try looksLikeLegacyTaina(host, name)) {
        host.err("o nome de container '{s}' ja esta em uso por outro servico. Nada foi alterado; escolha outro TAINA_CONTAINER ou verifique o container antes de remove-lo.", .{name});
        return error.DriverFailed;
    }

    const fingerprint = try configFingerprint(host, cfg);
    const label_format = "{{index .Config.Labels \"io.taina.config\"}}";
    const label_argv = [_][]const u8{ host.progs.docker, "inspect", "--format", label_format, name };
    const label = try host.capture(&label_argv);
    defer host.freeCapture(label);
    if (!label.ok()) {
        host.err("nao consegui comparar a configuracao do container '{s}'.", .{cfg.container});
        return error.DriverFailed;
    }
    if (!std.mem.eql(u8, label.line(), fingerprint)) return false;

    const env_argv = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", name };
    const actual_env = try host.capture(&env_argv);
    defer host.freeCapture(actual_env);
    if (!actual_env.ok()) {
        host.err("nao consegui comparar o ambiente do container '{s}'.", .{cfg.container});
        return error.DriverFailed;
    }
    return envContainsExpected(host, cfg, actual_env.stdout);
}

fn looksLikeLegacyTaina(host: *proc.Host, name: []const u8) Error!bool {
    const env_argv = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", name };
    const env = try host.capture(&env_argv);
    defer host.freeCapture(env);
    if (!env.ok()) return error.DriverFailed;
    return hasEnvLine(env.stdout, "DATABASE_PATH=/app/data/taina.db") and
        hasEnvLine(env.stdout, "PHX_SERVER=true") and
        hasEnvLine(env.stdout, "STORAGE_ROOT=/app/storage") and
        hasEnvPrefix(env.stdout, "SECRET_KEY_BASE=");
}

fn hasEnvLine(env: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, env, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), expected)) return true;
    }
    return false;
}

fn hasEnvPrefix(env: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, env, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix) and line.len > prefix.len) return true;
    }
    return false;
}

fn envContainsExpected(host: *proc.Host, cfg: *const config.Config, actual: []const u8) Error!bool {
    const expected = try containerEnvBody(host, cfg);
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    while (expected_lines.next()) |wanted| {
        if (wanted.len == 0) continue;
        var actual_lines = std.mem.splitScalar(u8, actual, '\n');
        var found = false;
        while (actual_lines.next()) |line| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), wanted)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// This label excludes the secret. The secret is compared directly against
/// the container environment captured by `docker inspect` and is never logged.
fn configFingerprint(host: *proc.Host, cfg: *const config.Config) Error![]const u8 {
    const fields = [_][]const u8{
        cfg.container,
        cfg.image,
        cfg.network,
        cfg.domain,
        cfg.db_dir,
        cfg.storage_dir,
        cfg.backup_dir,
        try num(host, cfg.host_port),
        if (cfg.backup_enabled) "true" else "false",
        if (cfg.update_check) "true" else "false",
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(host.gpa);
    for (fields) |field| {
        try bytes.appendSlice(host.gpa, field);
        try bytes.append(host.gpa, 0);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes.items, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return host.gpa.dupe(u8, &hex) catch error.OutOfMemory;
}

// --- systemd -----------------------------------------------------------------

fn systemdSetup(host: *proc.Host) Error!u8 {
    host.err("'taina setup' nao instala nem reconfigura o backend systemd. A instalacao pertence ao modulo NixOS.", .{});
    host.printTo(.stderr, "  Configure services.taina e aplique com: sudo nixos-rebuild switch\n", .{});
    return error.DriverFailed;
}

fn systemdSimple(host: *proc.Host, comptime msg: []const u8, argv: []const []const u8) Error!u8 {
    host.step(msg, .{});
    return host.run(argv);
}

fn systemdStatus(host: *proc.Host, d: Systemd) Error!u8 {
    const argv = [_][]const u8{ host.progs.systemctl, "is-active", d.unit };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    host.out("servico: {s}", .{cap.line()});
    return if (cap.ok()) 0 else 1;
}

fn systemdLogs(host: *proc.Host, d: Systemd, opts: LogOpts) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const g = host.gpa;
    defer argv.deinit(g);
    try argv.appendSlice(g, &.{ host.progs.journalctl, "-u", d.unit });
    if (opts.follow) try argv.append(g, "-f");
    if (opts.tail) |n| {
        try argv.append(g, "-n");
        try argv.append(g, try num(host, n));
    }
    return host.run(argv.items);
}

fn systemdHealth(host: *proc.Host, cfg: *const config.Config) Error!Health {
    const url = std.fmt.allocPrint(host.gpa, "http://127.0.0.1:{d}/health", .{cfg.host_port}) catch return error.OutOfMemory;
    const argv = [_][]const u8{ "curl", "-fsS", "-o", "/dev/null", url };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    return if (cap.ok()) .healthy else .degraded;
}

fn systemdUpdate(host: *proc.Host) Error!u8 {
    host.note("no NixOS o update e do sistema, nao da CLI.", .{});
    host.out("    sudo nixos-rebuild switch --flake .#<host>", .{});
    return 0;
}

fn systemdRunOnce(host: *proc.Host, d: Systemd, ro: RunOnce) Error!u8 {
    const expr = try evalExpr(host, ro);
    return host.run(&.{ try releaseBin(host, d), "eval", expr });
}

fn systemdRestore(host: *proc.Host, d: Systemd, argv: []const []const u8) Error!u8 {
    host.step("parando o Taina (o restore troca o arquivo do banco)", .{});
    const stop_code = try host.run(&.{ host.progs.systemctl, "stop", d.unit });
    if (stop_code != 0) return stop_code;

    const expr = try evalExpr(host, .{ .verb = "restore", .argv = argv });
    const code: u8 = host.run(&.{ try releaseBin(host, d), "eval", expr }) catch {
        _ = host.run(&.{ host.progs.systemctl, "start", d.unit }) catch {};
        return error.DriverFailed;
    };

    host.step("subindo o Taina de novo", .{});
    const start_code = try host.run(&.{ host.progs.systemctl, "start", d.unit });
    if (code != 0) return code;
    return start_code;
}

fn releaseBin(host: *proc.Host, d: Systemd) Error![]const u8 {
    if (d.release.len > 0) return std.fmt.allocPrint(host.gpa, "{s}/bin/taina", .{d.release}) catch error.OutOfMemory;
    return "taina";
}

fn systemdDescribe(host: *proc.Host, d: Systemd) Error!u8 {
    host.out("backend: systemd", .{});
    host.out("unit: {s}", .{d.unit});
    host.out("release: {s}", .{if (d.release.len > 0) d.release else "(na PATH)"});
    return 0;
}

fn noopLifecycle(host: *proc.Host, verb: []const u8) Error!u8 {
    host.note("'{s}' e do systemd (modulo NixOS), nao da CLI.", .{verb});
    return 0;
}

// --- shared ------------------------------------------------------------------

/// The release entrypoint invocation: `Taina.CLI.main(["backup", "--out", ...])`.
fn evalExpr(host: *proc.Host, ro: RunOnce) Error![]const u8 {
    const g = host.gpa;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(g, "Taina.CLI.main([");
    try appendQuoted(g, &out, ro.verb);
    for (ro.argv) |a| {
        try out.appendSlice(g, ", ");
        try appendQuoted(g, &out, a);
    }
    try out.appendSlice(g, "])");
    return out.toOwnedSlice(g) catch error.OutOfMemory;
}

fn appendQuoted(g: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(g, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(g, '\\');
        try out.append(g, c);
    }
    try out.append(g, '"');
}

fn num(host: *proc.Host, n: u64) Error![]const u8 {
    return std.fmt.allocPrint(host.gpa, "{d}", .{n}) catch error.OutOfMemory;
}

fn generateSecret(host: *proc.Host) Error![]const u8 {
    var raw: [48]u8 = undefined;
    host.io.random(&raw);
    const enc = std.base64.standard.Encoder;
    const out = host.gpa.alloc(u8, enc.calcSize(raw.len)) catch return error.OutOfMemory;
    _ = enc.encode(out, &raw);
    return out;
}

fn randSuffix(host: *proc.Host) Error![]const u8 {
    var raw: [4]u8 = undefined;
    host.io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return host.gpa.dupe(u8, &hex) catch error.OutOfMemory;
}
