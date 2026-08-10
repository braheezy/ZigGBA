//! This module implements runtime APIs for code running on a GBA.

const gba = @This();

pub const bios = @import("bios/mod.zig");
pub const ColorRgb555 = @import("graphics/color.zig").ColorRgb555;
pub const debug = @import("debug/mod.zig");
pub const display = @import("display/mod.zig");
pub const format = @import("format.zig");
pub const Header = @import("header.zig").Header;
pub const image = @import("graphics/image.zig");
pub const input = @import("input.zig");
pub const interrupt = @import("interrupt.zig");
pub const math = @import("math/mod.zig");
pub const mem = @import("memory/mod.zig");
pub const sound = @import("sound.zig");
pub const text = @import("text/mod.zig");
pub const Timer = @import("timer.zig").Timer;
pub const timers = @import("timer.zig").timers;
