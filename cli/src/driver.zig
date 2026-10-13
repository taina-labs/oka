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
            .systemd => noopLifecycle(host, "setup"),
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

    pub fn describe(self: Driver, host: *proc.Host, cfg: *const config.Config) Error!u8 {
        return switch (self) {
            .docker => |d| dockerDescribe(host, d, cfg),
            .systemd => |d| systemdDescribe(host, d),
        };
    }
};

// --- docker ------------------------------------------------------------------

fn dockerSetup(host: *proc.Host, cfg: *const config.Config) Error!u8 {
    var mutable = cfg.*;
    if (mutable.secret.len == 0) mutable.secret = try generateSecret(host);
    try config.save(host, &mutable);

    host.step("criando a rede {s}", .{mutable.network});
    _ = host.run(&.{ host.progs.docker, "network", "create", mutable.network }) catch {};

    host.step("subindo o Taina", .{});
    const dir = try host.makeTempDir();
    defer host.removeTempDir(dir);
    const env_file = try writeContainerEnv(host, &mutable, dir);
    const argv = try runArgs(host, &mutable, env_file);
    const code = try host.run(argv);
    if (code != 0) return code;

    host.step("esperando o Taina subir (no primeiro boot pode levar um minuto)", .{});
    if (!try waitHealthy(host, &mutable)) {
        host.err("o Taina nao ficou saudavel a tempo. Veja: docker logs -f {s}", .{mutable.container});
        return error.DriverFailed;
    }
    host.out("", .{});
    host.out("O Taina esta no ar. Abra https://{s}/setup", .{if (mutable.domain.len > 0) mutable.domain else "localhost"});
    return 0;
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

    host.step("subindo a versao nova", .{});
    const dir = try host.makeTempDir();
    defer host.removeTempDir(dir);
    const env_file = try writeContainerEnv(host, &mutable, dir);
    const argv = try runArgs(host, &mutable, env_file);
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

fn dockerDescribe(host: *proc.Host, d: Docker, cfg: *const config.Config) Error!u8 {
    host.out("backend: docker", .{});
    host.out("container: {s}", .{d.container});
    host.out("network: {s}", .{d.network});
    host.out("image: {s}", .{cfg.image});
    host.out("config: {s}", .{cfg.path});
    return 0;
}

/// The full `docker run` argv for the app container. Used by setup and update.
fn runArgs(host: *proc.Host, cfg: *const config.Config, env_file: []const u8) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const g = host.gpa;
    try argv.appendSlice(g, &.{ host.progs.docker, "run", "-d", "--name", cfg.container });
    try argv.appendSlice(g, &.{ "--network", cfg.network, "--restart", "unless-stopped" });
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
    var out: std.ArrayList(u8) = .empty;
    const phx_host = if (cfg.domain.len > 0) cfg.domain else "localhost";
    const body = std.fmt.allocPrint(g,
        \\DATABASE_PATH=/app/data/taina.db
        \\PHX_HOST={s}
        \\PHX_SERVER=true
        \\PORT=4000
        \\STORAGE_ROOT=/app/storage
        \\BACKUP_ENABLED=false
        \\BACKUP_DIR=/app/backups
        \\TAINA_UPDATE_CHECK={s}
        \\SECRET_KEY_BASE={s}
        \\
    , .{ phx_host, if (cfg.update_check) "true" else "false", cfg.secret }) catch return error.OutOfMemory;
    try out.appendSlice(g, body);
    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = out.items }) catch return error.DriverFailed;
    Io.Dir.cwd().setFilePermissions(host.io, path, .fromMode(0o600), .{}) catch {};
    return path;
}

fn waitHealthy(host: *proc.Host, cfg: *const config.Config) Error!bool {
    const d = Docker{ .container = cfg.container, .network = cfg.network };
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (try dockerHealth(host, d) == .healthy) return true;
        host.printTo(.stdout, ".", .{});
        host.io.sleep(Io.Duration.fromSeconds(5), .real) catch {};
    }
    return false;
}

fn containerExists(host: *proc.Host, name: []const u8) Error!bool {
    const argv = [_][]const u8{ host.progs.docker, "inspect", "--format", "{{.Id}}", name };
    const cap = try host.capture(&argv);
    defer host.freeCapture(cap);
    return cap.ok();
}

// --- systemd -----------------------------------------------------------------

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
    const bin = if (d.release.len > 0)
        (std.fmt.allocPrint(host.gpa, "{s}/bin/taina", .{d.release}) catch return error.OutOfMemory)
    else
        "taina";
    return host.run(&.{ bin, "eval", expr });
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
