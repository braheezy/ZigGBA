//! Test root for SDK modules that import shared code from `src/gba`.

test {
    _ = @import("math/mod.zig");
    _ = @import("format.zig");
    _ = @import("display/vram.zig");
    _ = @import("display/object.zig");
    _ = @import("display/palette.zig");
}
