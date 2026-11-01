//! The box settings: `taina.conf` (key=value) plus the TAINA_* environment.
const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");

pub const default_path = "taina.conf";

pub const Config = struct {
    path: []const u8,
    image: []const u8 = "ghcr.io/taina-labs/taina:latest",
    container: []const u8 = "taina-app",
    network: []const u8 = "taina",
    host_port: u16 = 4000,
    domain: []const u8 = "",
    db_dir: []const u8 = "",
    storage_dir: []const u8 = "",
    backup_dir: []const u8 = "",
    secret: []const u8 = "",
    update_check: bool = false,
    backup_enabled: bool = false,

    file_exists: bool = false,
    file_content: []const u8 = "",
    has_secret_key: bool = false,
    secret_value_start: usize = 0,
    secret_value_end: usize = 0,
};

pub fn load(host: *proc.Host, path: []const u8) proc.Error!Config {
    var cfg = Config{ .path = path };
    const content = Io.Dir.cwd().readFileAlloc(host.io, path, host.gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            host.err("nao consegui ler '{s}'. Verifique o caminho e as permissoes.", .{path});
            return error.ConfigIO;
        },
    };
    if (content) |bytes| {
        cfg.file_exists = true;
        cfg.file_content = bytes;
        try parse(host, &cfg, bytes);
    }

    try applyEnvironment(host, &cfg);
    try validate(host, &cfg);
    return cfg;
}

pub fn validate(host: *proc.Host, cfg: *const Config) proc.Error!void {
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "TAINA_IMAGE", .value = cfg.image },
        .{ .key = "TAINA_CONTAINER", .value = cfg.container },
        .{ .key = "TAINA_NETWORK", .value = cfg.network },
        .{ .key = "TAINA_DOMAIN", .value = cfg.domain },
        .{ .key = "TAINA_DB_DIR", .value = cfg.db_dir },
        .{ .key = "TAINA_STORAGE_DIR", .value = cfg.storage_dir },
        .{ .key = "TAINA_BACKUP_DIR", .value = cfg.backup_dir },
        .{ .key = "SECRET_KEY_BASE", .value = cfg.secret },
    };
    for (values) |item| {
        if (std.mem.indexOfAny(u8, item.value, "\r\n\x00") != null) {
            host.err("configuracao invalida: {s} nao pode conter quebras de linha ou NUL.", .{item.key});
            return error.ConfigInvalid;
        }
    }
    if (cfg.image.len == 0 or cfg.container.len == 0 or cfg.network.len == 0) {
        host.err("TAINA_IMAGE, TAINA_CONTAINER e TAINA_NETWORK nao podem ser vazios.", .{});
        return error.ConfigInvalid;
    }
    if (cfg.host_port == 0) {
        host.err("TAINA_HOST_PORT nao pode ser zero.", .{});
        return error.ConfigInvalid;
    }
}

fn applyEnvironment(host: *proc.Host, cfg: *Config) proc.Error!void {
    if (host.get("TAINA_IMAGE")) |v| {
        try validateEnvText(host, "TAINA_IMAGE", v);
        if (v.len == 0) return invalidEnvironment(host, "TAINA_IMAGE", "nao pode ser vazio");
        cfg.image = v;
    }
    if (host.get("TAINA_CONTAINER")) |v| {
        try validateEnvText(host, "TAINA_CONTAINER", v);
        if (v.len == 0) return invalidEnvironment(host, "TAINA_CONTAINER", "nao pode ser vazio");
        cfg.container = v;
    }
    if (host.get("TAINA_NETWORK")) |v| {
        try validateEnvText(host, "TAINA_NETWORK", v);
        if (v.len == 0) return invalidEnvironment(host, "TAINA_NETWORK", "nao pode ser vazio");
        cfg.network = v;
    }
    if (host.get("TAINA_DOMAIN")) |v| {
        try validateEnvText(host, "TAINA_DOMAIN", v);
        cfg.domain = v;
    }
    if (host.get("TAINA_DB_DIR")) |v| {
        try validateEnvText(host, "TAINA_DB_DIR", v);
        cfg.db_dir = v;
    }
    if (host.get("TAINA_STORAGE_DIR")) |v| {
        try validateEnvText(host, "TAINA_STORAGE_DIR", v);
        cfg.storage_dir = v;
    }
    if (host.get("TAINA_BACKUP_DIR")) |v| {
        try validateEnvText(host, "TAINA_BACKUP_DIR", v);
        cfg.backup_dir = v;
    }
    if (host.get("SECRET_KEY_BASE")) |v| {
        try validateEnvText(host, "SECRET_KEY_BASE", v);
        if (v.len > 0) cfg.secret = v;
    }
    if (host.get("TAINA_HOST_PORT")) |v| cfg.host_port = try parsePort(host, "ambiente TAINA_HOST_PORT", 0, v);
    if (host.get("TAINA_UPDATE_CHECK")) |v| cfg.update_check = try parseBool(host, "ambiente TAINA_UPDATE_CHECK", 0, v);
    if (host.get("TAINA_BACKUP_ENABLED")) |v| cfg.backup_enabled = try parseBool(host, "ambiente TAINA_BACKUP_ENABLED", 0, v);
}

fn parse(host: *proc.Host, cfg: *Config, content: []const u8) proc.Error!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    var seen_keys: [key_count]bool = .{ false, false, false, false, false, false, false, false, false, false, false };
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            return invalidLine(host, cfg.path, line_number, "sintaxe invalida; esperado CHAVE=VALOR");
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return invalidLine(host, cfg.path, line_number, "chave vazia");
        const key_index = keyIndex(key) orelse {
            host.err("'{s}', linha {d}: chave desconhecida '{s}'.", .{ cfg.path, line_number, key });
            return error.ConfigInvalid;
        };

        if (seen_keys[key_index]) {
            host.err("'{s}', linha {d}: chave duplicada '{s}'.", .{ cfg.path, line_number, key });
            return error.ConfigInvalid;
        }
        seen_keys[key_index] = true;
        if (std.mem.indexOfAny(u8, value, "\r\x00") != null) {
            return invalidLine(host, cfg.path, line_number, "valor nao pode conter carriage return ou NUL");
        }

        if (std.mem.eql(u8, key, "TAINA_IMAGE")) {
            if (value.len == 0) return invalidLine(host, cfg.path, line_number, "TAINA_IMAGE nao pode ser vazio");
            cfg.image = value;
        } else if (std.mem.eql(u8, key, "TAINA_CONTAINER")) {
            if (value.len == 0) return invalidLine(host, cfg.path, line_number, "TAINA_CONTAINER nao pode ser vazio");
            cfg.container = value;
        } else if (std.mem.eql(u8, key, "TAINA_NETWORK")) {
            if (value.len == 0) return invalidLine(host, cfg.path, line_number, "TAINA_NETWORK nao pode ser vazio");
            cfg.network = value;
        } else if (std.mem.eql(u8, key, "TAINA_DOMAIN")) {
            cfg.domain = value;
        } else if (std.mem.eql(u8, key, "TAINA_DB_DIR")) {
            cfg.db_dir = value;
        } else if (std.mem.eql(u8, key, "TAINA_STORAGE_DIR")) {
            cfg.storage_dir = value;
        } else if (std.mem.eql(u8, key, "TAINA_BACKUP_DIR")) {
            cfg.backup_dir = value;
        } else if (std.mem.eql(u8, key, "SECRET_KEY_BASE")) {
            cfg.secret = value;
            cfg.has_secret_key = true;
            const value_start = lineOffset(content, line) + eq + 1;
            const raw_line_start = lineOffset(content, raw);
            const raw_line_end = raw_line_start + raw.len - @intFromBool(std.mem.endsWith(u8, raw, "\r"));
            const raw_value = content[value_start..raw_line_end];
            const leading = raw_value.len - std.mem.trimStart(u8, raw_value, " \t").len;
            const trimmed = std.mem.trim(u8, raw_value, " \t\r");
            cfg.secret_value_start = value_start + leading;
            cfg.secret_value_end = cfg.secret_value_start + trimmed.len;
        } else if (std.mem.eql(u8, key, "TAINA_HOST_PORT")) {
            cfg.host_port = try parsePort(host, cfg.path, line_number, value);
        } else if (std.mem.eql(u8, key, "TAINA_UPDATE_CHECK")) {
            cfg.update_check = try parseBool(host, cfg.path, line_number, value);
        } else if (std.mem.eql(u8, key, "TAINA_BACKUP_ENABLED")) {
            cfg.backup_enabled = try parseBool(host, cfg.path, line_number, value);
        }
    }
}

// The key list is deliberately closed. This is not a passthrough env file.
const key_count = 11;
fn keyIndex(key: []const u8) ?usize {
    const keys = [_][]const u8{
        "TAINA_IMAGE",        "TAINA_CONTAINER",      "TAINA_NETWORK",
        "TAINA_DOMAIN",       "TAINA_DB_DIR",         "TAINA_STORAGE_DIR",
        "TAINA_BACKUP_DIR",   "SECRET_KEY_BASE",      "TAINA_HOST_PORT",
        "TAINA_UPDATE_CHECK", "TAINA_BACKUP_ENABLED",
    };
    for (keys, 0..) |known, i| {
        if (std.mem.eql(u8, key, known)) return i;
    }
    return null;
}

fn parsePort(host: *proc.Host, source: []const u8, line: usize, value: []const u8) proc.Error!u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch {
        if (line > 0) {
            try invalidLine(host, source, line, "TAINA_HOST_PORT deve ser um numero entre 1 e 65535");
            unreachable;
        }
        try invalidEnvironment(host, source, "deve ser um numero entre 1 e 65535");
        unreachable;
    };
    if (port == 0) {
        if (line > 0) {
            try invalidLine(host, source, line, "TAINA_HOST_PORT nao pode ser zero");
            unreachable;
        }
        try invalidEnvironment(host, source, "nao pode ser zero");
        unreachable;
    }
    return port;
}

fn parseBool(host: *proc.Host, source: []const u8, line: usize, value: []const u8) proc.Error!bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
    if (line > 0) {
        try invalidLine(host, source, line, "booleano invalido; use true, false, 1 ou 0");
        unreachable;
    }
    try invalidEnvironment(host, source, "use true, false, 1 ou 0");
    unreachable;
}

fn invalidLine(host: *proc.Host, path: []const u8, line: usize, reason: []const u8) proc.Error!void {
    host.err("'{s}', linha {d}: {s}.", .{ path, line, reason });
    return error.ConfigInvalid;
}

fn invalidEnvironment(host: *proc.Host, key: []const u8, reason: []const u8) proc.Error!void {
    host.err("variavel {s} invalida: {s}.", .{ key, reason });
    return error.ConfigInvalid;
}

fn validateEnvText(host: *proc.Host, key: []const u8, value: []const u8) proc.Error!void {
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") == null) return;
    host.err("variavel {s} invalida: nao pode conter quebras de linha ou NUL.", .{key});
    return error.ConfigInvalid;
}

fn lineOffset(content: []const u8, raw_line: []const u8) usize {
    const end = @intFromPtr(raw_line.ptr) - @intFromPtr(content.ptr);
    return end;
}

/// Create the first config with owner-only permissions. Existing config files
/// are never passed through this function.
pub fn createInitial(host: *proc.Host, cfg: *const Config) proc.Error!void {
    const g = host.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);
    try out.appendSlice(g, "# Created by taina setup. Keep this file private.\n");
    try writePair(g, &out, "TAINA_IMAGE", cfg.image);
    try writePair(g, &out, "TAINA_CONTAINER", cfg.container);
    try writePair(g, &out, "TAINA_NETWORK", cfg.network);
    try writePair(g, &out, "TAINA_DOMAIN", cfg.domain);
    try writePair(g, &out, "TAINA_DB_DIR", cfg.db_dir);
    try writePair(g, &out, "TAINA_STORAGE_DIR", cfg.storage_dir);
    try writePair(g, &out, "TAINA_BACKUP_DIR", cfg.backup_dir);
    try writePair(g, &out, "SECRET_KEY_BASE", cfg.secret);
    const rest = std.fmt.allocPrint(
        g,
        "TAINA_HOST_PORT={d}\nTAINA_UPDATE_CHECK={s}\nTAINA_BACKUP_ENABLED={s}\n",
        .{ cfg.host_port, if (cfg.update_check) "true" else "false", if (cfg.backup_enabled) "true" else "false" },
    ) catch return error.OutOfMemory;
    try out.appendSlice(g, rest);
    try atomicWrite(host, cfg.path, out.items, false);
}

/// Add or replace only the empty/missing secret value in an existing file.
/// Comments, order, and all unrelated bytes remain untouched.
pub fn persistSecret(host: *proc.Host, cfg: *const Config) proc.Error!void {
    const g = host.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);

    if (cfg.has_secret_key) {
        try out.appendSlice(g, cfg.file_content[0..cfg.secret_value_start]);
        try out.appendSlice(g, cfg.secret);
        try out.appendSlice(g, cfg.file_content[cfg.secret_value_end..]);
    } else {
        try out.appendSlice(g, cfg.file_content);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(g, '\n');
        try writePair(g, &out, "SECRET_KEY_BASE", cfg.secret);
    }
    try atomicWrite(host, cfg.path, out.items, true);
}

fn atomicWrite(host: *proc.Host, path: []const u8, bytes: []const u8, replace: bool) proc.Error!void {
    var atomic = Io.Dir.cwd().createFileAtomic(host.io, path, .{
        .permissions = .fromMode(0o600),
        .replace = replace,
    }) catch {
        host.err("nao consegui criar/atualizar '{s}'. Verifique se o diretorio existe e se voce tem permissao de escrita.", .{path});
        return error.ConfigIO;
    };
    defer atomic.deinit(host.io);
    atomic.file.writeStreamingAll(host.io, bytes) catch {
        host.err("nao consegui gravar '{s}'. Verifique o espaco em disco e as permissoes.", .{path});
        return error.ConfigIO;
    };
    if (replace) {
        atomic.replace(host.io) catch {
            host.err("nao consegui substituir '{s}' atomicamente. Verifique as permissoes e tente novamente.", .{path});
            return error.ConfigIO;
        };
    } else {
        atomic.link(host.io) catch {
            host.err("nao consegui criar '{s}' atomicamente. Verifique se o diretorio existe e se voce tem permissao de escrita.", .{path});
            return error.ConfigIO;
        };
    }
}

fn writePair(g: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) proc.Error!void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.ConfigInvalid;
    const line = std.fmt.allocPrint(g, "{s}={s}\n", .{ key, value }) catch return error.OutOfMemory;
    try out.appendSlice(g, line);
}
