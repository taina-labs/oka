//! Binary root. The module root stays at `cli/` so tests can embed scripts
//! from `test/` and reference `src/` the same way.
pub const main = @import("src/main.zig").main;

test {
    _ = @import("src/main.zig");
    _ = @import("src/proc.zig");
    _ = @import("src/config.zig");
    _ = @import("src/driver.zig");
    _ = @import("src/testutil.zig");
    _ = @import("src/main_test.zig");
}
