//! taina: the operator CLI for a Taina box. It owns the docker container (the
//! base [setup/up/down/update] verbs) and forwards domain verbs to the release
//! via `bin/taina eval`. On NixOS it is a thin read/ops layer over the module's
//! systemd unit, so the operator command set does not change.
const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const config = @import("config.zig");
const build_options = @import("build_options");

const Error = proc.Error;

const usage_text =
    \\usage: taina [--backend docker|systemd] [--config PATH] <command> [args...]
    \\
    \\Caixa (ciclo de vida, so docker):
    \\  setup [--domain D]        instala e sobe o Taina
    \\  up | down | restart       sobe, para (os dados ficam) e reinicia
    \\  update [--tag T]          baixa e sobe a versao nova (guarda rollback)
    \\
    \\Operacao (unificado):
    \\  status                    estado do servico
    \\  logs [-f] [--tail N]      logs
    \\  health                    checa /health
    \\  backend                   imprime o backend e os caminhos
    \\  version                   versao da CLI
    \\
    \\Dominio (roda dentro da release):
    \\  backup [--out DIR]        backup (banco + storage)
    \\  restore <arquivo.tar.gz>  restauracao (pare a caixa antes)
    \\  doctor                    diagnostico da caixa
    \\
    \\Environment: TAINA_BACKEND TAINA_CONFIG TAINA_IMAGE TAINA_CONTAINER
    \\  TAINA_NETWORK TAINA_DOMAIN TAINA_HOST_PORT TAINA_DB_DIR TAINA_STORAGE_DIR
    \\  TAINA_BACKUP_DIR SECRET_KEY_BASE TAINA_RELEASE
    \\
;

var backend_flag: ?driver.Kind = null;
var config_path: []const u8 = config.default_path;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var host = proc.Host{
        .gpa = init.arena.allocator(),
        .io = init.io,
        .environ = init.environ_map,
    };
    const user_args = if (args.len > 0) args[1..] else args;
    const code = run(&host, user_args) catch |e| mapError(e);
    std.process.exit(code);
}

/// Frozen exit codes: 0 ok, 1 domain failure, 2 usage, 3 driver/environment.
fn mapError(e: anyerror) u8 {
    return switch (e) {
        error.Usage, error.NotATty => 2,
        else => 3,
    };
}

pub fn run(host: *proc.Host, args: []const []const u8) Error!u8 {
    backend_flag = null;
    if (host.get("TAINA_CONFIG")) |p| {
        if (p.len > 0) config_path = p;
    }
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(host);
            return 0;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return usage(host, "--config precisa de um caminho", .{});
            config_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return usage(host, "--backend precisa de um valor: docker ou systemd", .{});
            backend_flag = parseKind(args[i]) orelse return usage(host, "backend desconhecido '{s}'. Use docker ou systemd", .{args[i]});
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const value = arg["--backend=".len..];
            backend_flag = parseKind(value) orelse return usage(host, "backend desconhecido '{s}'. Use docker ou systemd", .{value});
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(host, "flag global desconhecida '{s}'", .{arg});
        } else break;
    }
    const rest = args[i..];
    if (rest.len == 0) {
        printUsage(host);
        return error.Usage;
    }
    return dispatch(host, rest);
}

fn usage(host: *proc.Host, comptime fmt: []const u8, args: anytype) Error!u8 {
    host.err(fmt, args);
    host.printTo(.stderr, "rode 'taina --help' para a lista de comandos.\n", .{});
    return error.Usage;
}

fn printUsage(host: *proc.Host) void {
    host.printTo(.stdout, usage_text, .{});
}

fn dispatch(host: *proc.Host, cmd: []const []const u8) Error!u8 {
    const name = cmd[0];
    const rest = cmd[1..];
    if (std.mem.eql(u8, name, "help")) {
        printUsage(host);
        return 0;
    }
    if (std.mem.eql(u8, name, "version")) {
        host.out("taina {s}", .{build_options.cli_version});
        return 0;
    }
    if (std.mem.eql(u8, name, "setup")) return setup(host, rest);
    if (std.mem.eql(u8, name, "up")) return lifecycle(host, .up, rest);
    if (std.mem.eql(u8, name, "down")) return lifecycle(host, .down, rest);
    if (std.mem.eql(u8, name, "restart")) return lifecycle(host, .restart, rest);
    if (std.mem.eql(u8, name, "status")) return lifecycle(host, .status, rest);
    if (std.mem.eql(u8, name, "update")) return update(host, rest);
    if (std.mem.eql(u8, name, "logs")) return logs(host, rest);
    if (std.mem.eql(u8, name, "health")) return health(host, rest);
    if (std.mem.eql(u8, name, "backend")) return backendCmd(host, rest);
    // Domain verbs: the release owns the logic; the driver forwards them.
    if (std.mem.eql(u8, name, "backup")) return forward(host, "backup", rest);
    if (std.mem.eql(u8, name, "restore")) return forward(host, "restore", rest);
    if (std.mem.eql(u8, name, "doctor")) return forward(host, "doctor", rest);
    _ = try usage(host, "comando desconhecido '{s}'", .{name});
    return error.Usage;
}

const Lifecycle = enum { up, down, restart, status };

fn setup(host: *proc.Host, args: []const []const u8) Error!u8 {
    var domain: ?[]const u8 = null;
    var j: usize = 0;
    while (j < args.len) : (j += 1) {
        const a = args[j];
        if (std.mem.eql(u8, a, "--domain")) {
            j += 1;
            if (j >= args.len) return usage(host, "--domain precisa de um valor", .{});
            domain = args[j];
        } else if (std.mem.startsWith(u8, a, "--domain=")) {
            domain = a["--domain=".len..];
        } else return usage(host, "'setup' nao entende '{s}'", .{a});
    }
    var cfg = config.load(host, config_path);
    if (domain) |d| cfg.domain = d;
    const d = try detectDriver(host, &cfg);
    return d.setup(host, &cfg);
}

fn lifecycle(host: *proc.Host, which: Lifecycle, args: []const []const u8) Error!u8 {
    if (args.len > 0) return usage(host, "'{s}' nao leva argumentos", .{@tagName(which)});
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return switch (which) {
        .up => d.up(host),
        .down => d.down(host),
        .restart => d.restart(host),
        .status => d.status(host),
    };
}

fn update(host: *proc.Host, args: []const []const u8) Error!u8 {
    var tag: ?[]const u8 = null;
    var j: usize = 0;
    while (j < args.len) : (j += 1) {
        const a = args[j];
        if (std.mem.eql(u8, a, "--tag")) {
            j += 1;
            if (j >= args.len) return usage(host, "--tag precisa de um valor", .{});
            tag = args[j];
        } else if (std.mem.startsWith(u8, a, "--tag=")) {
            tag = a["--tag=".len..];
        } else return usage(host, "'update' nao entende '{s}'", .{a});
    }
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return d.update(host, &cfg, tag);
}

fn logs(host: *proc.Host, args: []const []const u8) Error!u8 {
    var opts = driver.LogOpts{};
    var j: usize = 0;
    while (j < args.len) : (j += 1) {
        const a = args[j];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--follow")) {
            opts.follow = true;
        } else if (std.mem.eql(u8, a, "--tail")) {
            j += 1;
            if (j >= args.len) return usage(host, "--tail precisa de um numero", .{});
            opts.tail = std.fmt.parseInt(u64, args[j], 10) catch return usage(host, "--tail precisa de um numero", .{});
        } else if (std.mem.startsWith(u8, a, "--tail=")) {
            opts.tail = std.fmt.parseInt(u64, a["--tail=".len..], 10) catch return usage(host, "--tail precisa de um numero", .{});
        } else return usage(host, "'logs' nao entende '{s}'", .{a});
    }
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return d.logs(host, opts);
}

fn health(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len > 0) return usage(host, "'health' nao leva argumentos", .{});
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return switch (try d.health(host, &cfg)) {
        .healthy => blk: {
            host.out("saudavel", .{});
            break :blk 0;
        },
        .degraded => blk: {
            host.err("nao esta saudavel. Veja: taina logs", .{});
            break :blk 1;
        },
    };
}

fn backendCmd(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len > 0) return usage(host, "'backend' nao leva argumentos", .{});
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return d.describe(host, &cfg);
}

fn forward(host: *proc.Host, verb: []const u8, args: []const []const u8) Error!u8 {
    var cfg = config.load(host, config_path);
    const d = try detectDriver(host, &cfg);
    return d.runOnce(host, .{ .verb = verb, .argv = args });
}

fn parseKind(value: []const u8) ?driver.Kind {
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "systemd")) return .systemd;
    return null;
}

fn detectDriver(host: *proc.Host, cfg: *const config.Config) Error!driver.Driver {
    if (backend_flag) |k| return explicit(host, cfg, k);
    if (host.get("TAINA_BACKEND")) |b| {
        if (b.len > 0) {
            const k = parseKind(b) orelse {
                host.err("TAINA_BACKEND deve ser docker ou systemd, veio: {s}.", .{b});
                return error.Usage;
            };
            return explicit(host, cfg, k);
        }
    }
    // The NixOS module exports TAINA_RELEASE; a systemd unit named taina also
    // marks the systemd backend. Otherwise docker owns the box.
    if (host.get("TAINA_RELEASE")) |r| {
        if (r.len > 0) return explicit(host, cfg, .systemd);
    }
    if (builtin.os.tag != .windows and commandExists(host, host.progs.systemctl) and unitExists(host, "taina")) {
        return explicit(host, cfg, .systemd);
    }
    if (commandExists(host, host.progs.docker)) return explicit(host, cfg, .docker);
    host.err("nao achei docker nem systemd. Instale o Docker, ou rode no NixOS.", .{});
    return error.DriverFailed;
}

fn explicit(host: *proc.Host, cfg: *const config.Config, k: driver.Kind) Error!driver.Driver {
    return switch (k) {
        .docker => driver.Driver{ .docker = .{ .container = cfg.container, .network = cfg.network } },
        .systemd => driver.Driver{ .systemd = .{ .unit = "taina", .release = host.get("TAINA_RELEASE") orelse "" } },
    };
}

fn commandExists(host: *proc.Host, prog: []const u8) bool {
    const argv = [_][]const u8{ prog, "--version" };
    const cap = host.capture(&argv) catch return false;
    defer host.freeCapture(cap);
    return cap.ok();
}

fn unitExists(host: *proc.Host, unit: []const u8) bool {
    const argv = [_][]const u8{ host.progs.systemctl, "cat", unit };
    const cap = host.capture(&argv) catch return false;
    defer host.freeCapture(cap);
    return cap.ok();
}
