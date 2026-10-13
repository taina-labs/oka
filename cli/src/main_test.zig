//! Dispatch, argv and exit-code tests, all through the fake docker/systemctl
//! shims (no real runtime).
const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");
const testutil = @import("testutil.zig");

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
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"help"}));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"version"}));
}

test "docker: status, logs and lifecycle go through docker" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

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
