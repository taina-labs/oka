//! Dispatch, argv and exit-code tests, all through the fake docker/systemctl
//! shims (no real runtime).
const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");
const testutil = @import("testutil.zig");
const proc = @import("proc.zig");

fn writeFile(ctx: *testutil.Ctx, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(ctx.host.io, .{ .sub_path = path, .data = content });
}

fn readFile(ctx: *testutil.Ctx, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.host.io, path, testing.allocator, .limited(1 << 20));
}

fn countAppRuns(invs: []const []const []const u8) usize {
    var count: usize = 0;
    for (invs) |inv| {
        if (inv.len == 0 or !std.mem.eql(u8, inv[0], "run")) continue;
        for (inv) |arg| {
            if (std.mem.eql(u8, arg, "--env-file")) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

fn invocationExists(invs: []const []const []const u8, command: []const u8) bool {
    for (invs) |inv| {
        if (inv.len > 0 and std.mem.eql(u8, inv[0], command)) return true;
    }
    return false;
}

fn hasArg(inv: []const []const u8, wanted: []const u8) bool {
    for (inv) |arg| {
        if (std.mem.eql(u8, arg, wanted)) return true;
    }
    return false;
}

test "dispatch: usage errors are usage (2)" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try testing.expectError(error.Usage, main.run(ctx.host, &.{"nonsense"}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "--backend", "wat", "up" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{"--backend"}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "logs", "--tail" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "logs", "--tail", "ten" }));
}

test "dispatch: --help/help/version exit 0" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"--help"}));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "TAINA_CONFIG") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "--config PATH") != null);
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"help"}));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"version"}));
}

test "docker: status, logs and lifecycle go through docker" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.seedContainer("running\n");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"status"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "inspect", "--format", "{{.State.Status}}", "taina-app" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "logs", "-f", "--tail", "100" }));
    const logs_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(logs_inv, "--follow");
    try testutil.Ctx.expectArg(logs_inv, "--tail");
    try testutil.Ctx.expectArg(logs_inv, "100");
    try testutil.Ctx.expectArg(logs_inv, "taina-app");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"down"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "stop", "taina-app" });
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"up"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "start", "taina-app" });
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"restart"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "restart", "taina-app" });
}

test "docker: setup writes the config and runs the container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKUP_ENABLED", "true");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "setup", "--domain", "nuvem.local" }));

    const invs = try ctx.invocations();
    var run_inv: ?[]const []const u8 = null;
    for (invs) |inv| {
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "run")) run_inv = inv;
    }
    try testing.expect(run_inv != null);
    const inv = run_inv.?;
    try testutil.Ctx.expectArg(inv, "-d");
    try testutil.Ctx.expectArg(inv, "--name");
    try testutil.Ctx.expectArg(inv, "--network");
    try testutil.Ctx.expectArg(inv, "--env-file");
    try testutil.Ctx.expectArg(inv, "-v");
    try testutil.Ctx.expectArg(inv, "ghcr.io/taina-labs/taina:latest");

    const cfg = try std.Io.Dir.cwd().readFileAlloc(ctx.host.io, try ctx.tmpPath("taina.conf"), testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "SECRET_KEY_BASE=") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "TAINA_DOMAIN=nuvem.local") != null);

    // The backup switch crossed the container boundary via the env-file.
    const log = try std.Io.Dir.cwd().readFileAlloc(ctx.host.io, ctx.log_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "ENVFILE:BACKUP_ENABLED=true") != null);
}

test "setup first use prompts and writes the default config privately" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const existing = std.Io.Dir.cwd().readFileAlloc(ctx.host.io, "taina.conf", testing.allocator, .limited(1 << 20)) catch null;
    if (existing) |bytes| {
        testing.allocator.free(bytes);
        return error.TestUnexpectedResult;
    }
    defer std.Io.Dir.cwd().deleteFile(ctx.host.io, "taina.conf") catch {};
    try ctx.env.put("TAINA_CONFIG", "");
    try ctx.env.put("TAINA_DOMAIN", "from-env.example");
    try ctx.env.put("TAINA_DB_DIR", "/srv/taina/db");
    try ctx.env.put("TAINA_BACKUP_ENABLED", "true");
    ctx.host.stdin_input_override = "\n\n\n\n\n\n\ns\n";
    proc.Host.stdin_tty_override = true;

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));

    const saved = try readFile(&ctx, "taina.conf");
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "TAINA_HOST_PORT=4000") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "TAINA_DOMAIN=from-env.example") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "TAINA_DB_DIR=/srv/taina/db") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "TAINA_BACKUP_ENABLED=true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "from-env.example") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "/srv/taina/db") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "SECRET_KEY_BASE=") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "Resumo da configuracao") != null);
    const stat = try std.Io.Dir.cwd().statFile(ctx.host.io, "taina.conf", .{});
    try testing.expectEqual(@as(usize, 0o600), @as(usize, @intCast(stat.permissions.toMode() & 0o777)));
}

test "setup honors --config and TAINA_CONFIG paths" {
    var flagged = try testutil.Ctx.init();
    defer flagged.deinit();
    const from_env = try flagged.tmpPath("from-env.conf");
    const from_flag = try flagged.tmpPath("from-flag.conf");
    try flagged.env.put("TAINA_CONFIG", from_env);
    flagged.host.stdin_input_override = "\n\n\n\n\n\n\ns\n";
    proc.Host.stdin_tty_override = true;
    try testing.expectEqual(@as(u8, 0), try main.run(flagged.host, &.{ "--config", from_flag, "setup" }));
    const from_flag_content = try readFile(&flagged, from_flag);
    defer testing.allocator.free(from_flag_content);
    try testing.expect(from_flag_content.len > 0);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(flagged.host.io, from_env, testing.allocator, .limited(1 << 20)));

    var equals = try testutil.Ctx.init();
    defer equals.deinit();
    const from_equals = try equals.tmpPath("from-equals.conf");
    const config_flag = try std.fmt.allocPrint(equals.host.gpa, "--config={s}", .{from_equals});
    try testing.expectEqual(@as(u8, 0), try main.run(equals.host, &.{ config_flag, "setup" }));
    const equals_content = try readFile(&equals, from_equals);
    defer testing.allocator.free(equals_content);
    try testing.expect(equals_content.len > 0);

    var from_environment = try testutil.Ctx.init();
    defer from_environment.deinit();
    const selected = try from_environment.tmpPath("selected.conf");
    try from_environment.env.put("TAINA_CONFIG", selected);
    from_environment.host.stdin_input_override = "\n\n\n\n\n\n\ns\n";
    proc.Host.stdin_tty_override = true;
    try testing.expectEqual(@as(u8, 0), try main.run(from_environment.host, &.{"setup"}));
    const saved = try readFile(&from_environment, selected);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "SECRET_KEY_BASE=") != null);
}

test "setup --config after the command selects the same config source" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const selected = try ctx.tmpPath("nested.conf");
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "setup", "--config", selected }));
    const saved = try readFile(&ctx, selected);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "SECRET_KEY_BASE=") != null);
}

test "existing config does not prompt or get rewritten" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    const original = "# operator comment\nTAINA_DOMAIN=box.example\nTAINA_HOST_PORT=4000\nSECRET_KEY_BASE=fixture-secret\n# keep this line\n";
    try writeFile(&ctx, path, original);
    ctx.host.stdin_input_override = null;
    proc.Host.stdin_tty_override = true;

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));

    const saved = try readFile(&ctx, path);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(original, saved);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "Instalacao inicial") == null);
}

test "non-tty setup never reads input and uses deterministic defaults" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    ctx.host.stdin_input_override = null;
    proc.Host.stdin_tty_override = false;

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "Instalacao inicial") == null);
    const invs = try ctx.invocations();
    try testing.expectEqual(@as(usize, 1), countAppRuns(invs));
}

test "--domain wins over its environment default in the first-use assistant" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_DOMAIN", "environment.example");
    ctx.host.stdin_input_override = "\n\n\n\n\n\ns\n";
    proc.Host.stdin_tty_override = true;

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "setup", "--domain", "flag.example" }));
    const path = ctx.host.get("TAINA_CONFIG").?;
    const saved = try readFile(&ctx, path);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "TAINA_DOMAIN=flag.example") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "flag.example") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "Dominio publico") == null);
}

test "environment and --domain precedence are execution-only for existing config" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    const original = "TAINA_DOMAIN=file.example\nTAINA_HOST_PORT=4100\nSECRET_KEY_BASE=config-secret\n";
    try writeFile(&ctx, path, original);
    try ctx.env.put("TAINA_DOMAIN", "env.example");
    try ctx.env.put("TAINA_HOST_PORT", "4200");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "setup", "--domain", "cli.example" }));
    const log1 = try readFile(&ctx, ctx.log_path);
    defer testing.allocator.free(log1);
    try testing.expect(std.mem.indexOf(u8, log1, "ENVFILE:PHX_HOST=cli.example") != null);
    var invs = try ctx.invocations();
    var saw_port = false;
    for (invs) |inv| {
        if (hasArg(inv, "127.0.0.1:4200:4000")) saw_port = true;
    }
    try testing.expect(saw_port);

    ctx.clearOutput();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const log2 = try readFile(&ctx, ctx.log_path);
    defer testing.allocator.free(log2);
    try testing.expect(std.mem.indexOf(u8, log2, "ENVFILE:PHX_HOST=env.example") != null);
    const saved = try readFile(&ctx, path);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(original, saved);
    invs = try ctx.invocations();
    try testing.expectEqual(@as(usize, 2), countAppRuns(invs));
}

test "canceling the first-use assistant creates no file or container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    ctx.host.stdin_input_override = "\n\n\n\n\n\n\nn\n";
    proc.Host.stdin_tty_override = true;

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(ctx.host.io, path, testing.allocator, .limited(1 << 20)));
    try testing.expectEqual(@as(usize, 0), (try ctx.invocations()).len);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "cancelada") != null);
}

test "setup adds a missing secret minimally and preserves it on re-run" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    const original = "# keep ordering\nTAINA_DOMAIN=box.example\n# no secret yet\n";
    try writeFile(&ctx, path, original);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const first = try readFile(&ctx, path);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.startsWith(u8, first, original));
    try testing.expect(std.mem.indexOf(u8, first, "# keep ordering") != null);
    const secret_at = (std.mem.indexOf(u8, first, "SECRET_KEY_BASE=") orelse return error.TestUnexpectedResult) + "SECRET_KEY_BASE=".len;
    const secret_end = std.mem.indexOfScalarPos(u8, first, secret_at, '\n') orelse return error.TestUnexpectedResult;
    const secret = first[secret_at..secret_end];
    try testing.expect(secret.len >= 64);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), secret) == null);
    const log = try readFile(&ctx, ctx.log_path);
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, secret) == null);
    try testing.expect(std.mem.indexOf(u8, log, "ENVFILE:SECRET_KEY_BASE") == null);

    ctx.clearOutput();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const second = try readFile(&ctx, path);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, 1), countAppRuns(try ctx.invocations()));
}

test "setup fills an empty secret value without replacing other lines" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    const original = "# operator header\nTAINA_DOMAIN=\nSECRET_KEY_BASE=   \n# keep final comment\n";
    try writeFile(&ctx, path, original);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const saved = try readFile(&ctx, path);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.startsWith(u8, saved, "# operator header\nTAINA_DOMAIN=\nSECRET_KEY_BASE=   "));
    try testing.expect(std.mem.endsWith(u8, saved, "\n# keep final comment\n"));
    try testing.expect(std.mem.indexOf(u8, saved, "SECRET_KEY_BASE=   \n") == null);
}

test "invalid config reports the path and line number" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    try writeFile(&ctx, path, "# comment\nTAINA_HOST_PORT=0\n");

    try testing.expectError(error.ConfigInvalid, main.run(ctx.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), path) != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "linha 2") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "zero") != null);
    try testing.expectEqual(@as(usize, 0), (try ctx.invocations()).len);
}

test "config parser rejects syntax, unknown and duplicate keys, booleans, and ports" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    const invalid_files = [_][]const u8{
        "# comment\nnot-a-pair\n",
        "TAINA_MYSTERY=value\n",
        "TAINA_DOMAIN=one.example\nTAINA_DOMAIN=two.example\n",
        "TAINA_UPDATE_CHECK=yes\n",
        "TAINA_HOST_PORT=65536\n",
    };
    for (invalid_files) |content| {
        try writeFile(&ctx, path, content);
        ctx.clearOutput();
        try testing.expectError(error.ConfigInvalid, main.run(ctx.host, &.{"setup"}));
        try testing.expect(std.mem.indexOf(u8, ctx.outputText(), path) != null);
        try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "linha") != null);
        try testing.expectEqual(@as(usize, 0), (try ctx.invocations()).len);
    }
}

test "empty optional domain and data directories are accepted" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = ctx.host.get("TAINA_CONFIG").?;
    try writeFile(&ctx, path, "TAINA_DOMAIN=\nTAINA_DB_DIR=\nTAINA_STORAGE_DIR=\nTAINA_BACKUP_DIR=\nSECRET_KEY_BASE=keep-this\n");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const invs = try ctx.invocations();
    var saw_db_volume = false;
    var saw_storage_volume = false;
    var saw_backup_volume = false;
    for (invs) |inv| {
        if (hasArg(inv, "taina_db:/app/data")) saw_db_volume = true;
        if (hasArg(inv, "taina_storage:/app/storage")) saw_storage_volume = true;
        if (hasArg(inv, "taina_backups:/app/backups")) saw_backup_volume = true;
    }
    try testing.expect(saw_db_volume);
    try testing.expect(saw_storage_volume);
    try testing.expect(saw_backup_volume);
}

test "config write failure explains how to fix the selected path" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const path = try ctx.tmpPath("missing-parent/taina.conf");

    try testing.expectError(error.ConfigIO, main.run(ctx.host, &.{ "--config", path, "setup" }));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), path) != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "permissao de escrita") != null);
    try testing.expectEqual(@as(usize, 0), countAppRuns(try ctx.invocations()));
}

test "repeated setup reuses a healthy matching container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    try testing.expectEqual(@as(usize, 1), countAppRuns(try ctx.invocations()));
    ctx.clearOutput();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const invs = try ctx.invocations();
    try testing.expectEqual(@as(usize, 1), countAppRuns(invs));
    try testing.expect(!invocationExists(invs, "stop"));
    try testing.expect(!invocationExists(invs, "rm"));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "ja esta configurado") != null);
}

test "setup starts an equivalent stopped container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    try ctx.setContainerStatus("exited\n");
    ctx.clearOutput();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const invs = try ctx.invocations();
    try testing.expect(invocationExists(invs, "start"));
    try testing.expectEqual(@as(usize, 1), countAppRuns(invs));
}

test "changed docker config recreates only the container and retains data mounts" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_DB_DIR", "/srv/taina/db");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const path = ctx.host.get("TAINA_CONFIG").?;
    const original = try readFile(&ctx, path);
    defer testing.allocator.free(original);
    const needle = "TAINA_HOST_PORT=4000";
    const at = std.mem.indexOf(u8, original, needle) orelse return error.TestUnexpectedResult;
    const changed = try std.fmt.allocPrint(testing.allocator, "{s}TAINA_HOST_PORT=4400{s}", .{ original[0..at], original[at + needle.len ..] });
    defer testing.allocator.free(changed);
    try writeFile(&ctx, path, changed);
    ctx.clearOutput();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const invs = try ctx.invocations();
    try testing.expect(invocationExists(invs, "stop"));
    try testing.expect(invocationExists(invs, "rm"));
    try testing.expectEqual(@as(usize, 2), countAppRuns(invs));
    try testing.expect(!invocationExists(invs, "volume"));
    var saw_mount = false;
    var saw_port = false;
    for (invs) |inv| {
        if (hasArg(inv, "/srv/taina/db:/app/data")) saw_mount = true;
        if (hasArg(inv, "127.0.0.1:4400:4000")) saw_port = true;
    }
    try testing.expect(saw_mount);
    try testing.expect(saw_port);
}

test "changing the configured container name replaces the managed container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    try ctx.env.put("TAINA_CONTAINER", "taina-renamed");
    ctx.clearOutput();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"setup"}));
    const invs = try ctx.invocations();
    try testing.expect(invocationExists(invs, "stop"));
    try testing.expect(invocationExists(invs, "rm"));
    try testing.expectEqual(@as(usize, 2), countAppRuns(invs));
    try testing.expect(hasArg(try ctx.lastInvocation(), "taina-renamed"));
}

test "setup reports network and permission errors" {
    var network = try testutil.Ctx.init();
    defer network.deinit();
    try network.env.put("TAINA_FAKE_NETWORK_ERROR", "1");
    try testing.expectError(error.DriverFailed, main.run(network.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, network.outputText(), "rede Docker") != null);
    try testing.expect(std.mem.indexOf(u8, network.outputText(), "permission denied") != null);
    try testing.expectEqual(@as(usize, 0), countAppRuns(try network.invocations()));

    var permissions = try testutil.Ctx.init();
    defer permissions.deinit();
    try permissions.env.put("TAINA_FAKE_PERMS_EXIT", "1");
    try testing.expectError(error.DriverFailed, main.run(permissions.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, permissions.outputText(), "permissoes") != null);
    try testing.expect(std.mem.indexOf(u8, permissions.outputText(), "imagem") != null);
    try testing.expectEqual(@as(usize, 0), countAppRuns(try permissions.invocations()));
}

test "setup prints honest local and optional public access addresses" {
    var local = try testutil.Ctx.init();
    defer local.deinit();
    try local.env.put("TAINA_HOST_PORT", "4545");
    try testing.expectEqual(@as(u8, 0), try main.run(local.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, local.outputText(), "http://127.0.0.1:4545/setup") != null);
    try testing.expect(std.mem.indexOf(u8, local.outputText(), "https://localhost") == null);

    var public = try testutil.Ctx.init();
    defer public.deinit();
    try public.env.put("TAINA_HOST_PORT", "5544");
    try public.env.put("TAINA_DOMAIN", "cloud.example");
    try testing.expectEqual(@as(u8, 0), try main.run(public.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, public.outputText(), "http://127.0.0.1:5544/setup") != null);
    try testing.expect(std.mem.indexOf(u8, public.outputText(), "https://cloud.example/setup") != null);
    try testing.expect(std.mem.indexOf(u8, public.outputText(), "Esse acesso so funciona depois que um proxy ou Tailscale") != null);
    try testing.expect(std.mem.indexOf(u8, public.outputText(), "outra porta publica") != null);
}

test "docker: update pulls the tag and recreates" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "update", "--tag", "v0.2.0" }));

    const invs = try ctx.invocations();
    var saw_pull = false;
    var saw_run = false;
    for (invs) |inv| {
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "pull")) {
            saw_pull = true;
            try testutil.Ctx.expectArg(inv, "ghcr.io/taina-labs/taina:v0.2.0");
        }
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "run")) saw_run = true;
    }
    try testing.expect(saw_pull);
    try testing.expect(saw_run);
}

test "docker: domain verbs forward to bin/taina eval" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"doctor"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "/app/bin/taina", "eval", "Taina.CLI.main([\"doctor\"])" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"backup"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "/app/bin/taina", "eval", "Taina.CLI.main([\"backup\"])" });
}

test "systemd: status and logs go through systemctl and journalctl" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKEND", "systemd");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"status"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "is-active", "taina" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "logs", "--tail", "5" }));
    const logs_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(logs_inv, "-u");
    try testutil.Ctx.expectArg(logs_inv, "-n");
}

test "systemd: lifecycle is a no-op and update points at nixos-rebuild" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKEND", "systemd");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"up"}));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"down"}));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"update"}));
}

test "systemd setup fails with NixOS module instructions" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKEND", "systemd");

    try testing.expectError(error.DriverFailed, main.run(ctx.host, &.{"setup"}));
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "services.taina") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.outputText(), "nixos-rebuild switch") != null);
    try testing.expectEqual(@as(usize, 0), (try ctx.invocations()).len);
}

test "systemd: a domain verb runs the release bin/taina" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKEND", "systemd");
    try ctx.env.put("TAINA_RELEASE", try ctx.makeRelease());

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"doctor"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "eval", "Taina.CLI.main([\"doctor\"])" });
}

test "exit codes propagate from the runtime" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_FAKE_EXIT", "1");
    try testing.expectEqual(@as(u8, 1), try main.run(ctx.host, &.{"down"}));
}

test "docker: restore stops the app, runs a one-off, then starts it" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", "b.tar.gz" }));

    const invs = try ctx.invocations();
    var stop_at: ?usize = null;
    var run_at: ?usize = null;
    var start_at: ?usize = null;
    for (invs, 0..) |inv, i| {
        if (inv.len < 1) continue;
        if (std.mem.eql(u8, inv[0], "exec")) return error.TestUnexpectedResult;
        if (std.mem.eql(u8, inv[0], "stop")) stop_at = i;
        if (std.mem.eql(u8, inv[0], "start")) start_at = i;
        if (std.mem.eql(u8, inv[0], "run")) {
            run_at = i;
            try testutil.Ctx.expectArg(inv, "--rm");
            try testutil.Ctx.expectArg(inv, "--volumes-from");
            try testutil.Ctx.expectArg(inv, "ghcr.io/taina-labs/taina:latest");
            try testutil.Ctx.expectTail(inv, &.{ "/app/bin/taina", "eval", "Taina.CLI.main([\"restore\", \"b.tar.gz\"])" });
        }
    }
    try testing.expect(stop_at != null);
    try testing.expect(run_at != null);
    try testing.expect(start_at != null);
    try testing.expect(stop_at.? < run_at.?);
    try testing.expect(run_at.? < start_at.?);
}

test "systemd: restore stops the unit and runs the release one-off" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("TAINA_BACKEND", "systemd");
    try ctx.env.put("TAINA_RELEASE", try ctx.makeRelease());

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", "b.tar.gz" }));

    const invs = try ctx.invocations();
    var saw_stop = false;
    var saw_start = false;
    var saw_eval = false;
    for (invs) |inv| {
        if (inv.len < 1) continue;
        if (std.mem.eql(u8, inv[0], "stop")) saw_stop = true;
        if (std.mem.eql(u8, inv[0], "start")) saw_start = true;
        if (std.mem.eql(u8, inv[0], "eval")) {
            saw_eval = true;
            try testutil.Ctx.expectTail(inv, &.{ "eval", "Taina.CLI.main([\"restore\", \"b.tar.gz\"])" });
        }
    }
    try testing.expect(saw_stop);
    try testing.expect(saw_start);
    try testing.expect(saw_eval);
}
