//! The box settings: `taina.conf` (chave=valor) plus the TAINA_* environment.
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
};

pub fn load(host: *proc.Host, path: []const u8) Config {
    var cfg = Config{ .path = path };
    if (Io.Dir.cwd().readFileAlloc(host.io, path, host.gpa, .limited(1 << 20)) catch null) |content| {
        parse(&cfg, content);
    }
    if (host.get("TAINA_IMAGE")) |v| cfg.image = v;
    if (host.get("TAINA_CONTAINER")) |v| cfg.container = v;
    if (host.get("TAINA_NETWORK")) |v| cfg.network = v;
    if (host.get("TAINA_DOMAIN")) |v| cfg.domain = v;
    if (host.get("TAINA_DB_DIR")) |v| cfg.db_dir = v;
    if (host.get("TAINA_STORAGE_DIR")) |v| cfg.storage_dir = v;
    if (host.get("TAINA_BACKUP_DIR")) |v| cfg.backup_dir = v;
    if (host.get("SECRET_KEY_BASE")) |v| cfg.secret = v;
    if (host.get("TAINA_HOST_PORT")) |v| cfg.host_port = std.fmt.parseInt(u16, v, 10) catch cfg.host_port;
    if (host.get("TAINA_UPDATE_CHECK")) |v| cfg.update_check = isTrue(v);
    return cfg;
}

fn isTrue(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

fn parse(cfg: *Config, content: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "TAINA_IMAGE")) {
            cfg.image = val;
        } else if (std.mem.eql(u8, key, "TAINA_CONTAINER")) {
            cfg.container = val;
        } else if (std.mem.eql(u8, key, "TAINA_NETWORK")) {
            cfg.network = val;
        } else if (std.mem.eql(u8, key, "TAINA_DOMAIN")) {
            cfg.domain = val;
        } else if (std.mem.eql(u8, key, "TAINA_DB_DIR")) {
            cfg.db_dir = val;
        } else if (std.mem.eql(u8, key, "TAINA_STORAGE_DIR")) {
            cfg.storage_dir = val;
        } else if (std.mem.eql(u8, key, "TAINA_BACKUP_DIR")) {
            cfg.backup_dir = val;
        } else if (std.mem.eql(u8, key, "SECRET_KEY_BASE")) {
            cfg.secret = val;
        } else if (std.mem.eql(u8, key, "TAINA_HOST_PORT")) {
            cfg.host_port = std.fmt.parseInt(u16, val, 10) catch cfg.host_port;
        } else if (std.mem.eql(u8, key, "TAINA_UPDATE_CHECK")) {
            cfg.update_check = isTrue(val);
        }
    }
}

pub fn save(host: *proc.Host, cfg: *const Config) proc.Error!void {
    const g = host.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);

    try out.appendSlice(g, "# Gerado pelo taina. Nao versione: tem o segredo da sessao.\n");
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
        "TAINA_HOST_PORT={d}\nTAINA_UPDATE_CHECK={s}\n",
        .{ cfg.host_port, if (cfg.update_check) "true" else "false" },
    ) catch return error.OutOfMemory;
    try out.appendSlice(g, rest);

    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = cfg.path, .data = out.items }) catch return error.DriverFailed;
    Io.Dir.cwd().setFilePermissions(host.io, cfg.path, .fromMode(0o600), .{}) catch {};
}

fn writePair(g: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) proc.Error!void {
    const line = std.fmt.allocPrint(g, "{s}={s}\n", .{ key, value }) catch return error.OutOfMemory;
    try out.appendSlice(g, line);
}
