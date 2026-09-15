//! Battery-backed SRAM and FRAM save backend.

const backend = @import("backend.zig");
const gba = @import("../gba.zig");

/// Portable capacity for cartridges and flash carts configured for SRAM saves.
pub const capacity = 32 * 1024;
/// SRAM supports byte writes, so records need no erase alignment.
pub const erase_alignment = 1;
/// Backend for 32 KiB battery-backed SRAM or compatible FRAM.
pub const Backend = struct {
    pub const capacity = 32 * 1024;
    pub const erase_alignment = 1;
    pub const Error = backend.Error;

    pub fn init() Backend {
        return .{};
    }

    pub fn read(_: *const Backend, offset: usize, output: []u8) Error!void {
        if (offset > Backend.capacity or output.len > Backend.capacity - offset) return error.OutOfBounds;
        for (output, 0..) |*byte, index| byte.* = gba.mem.sram[offset + index];
    }

    pub fn write(_: *Backend, offset: usize, input: []const u8) Error!void {
        if (offset > Backend.capacity or input.len > Backend.capacity - offset) return error.OutOfBounds;
        for (input, 0..) |byte, index| gba.mem.sram[offset + index] = byte;
    }

    pub fn erase(self: *Backend, offset: usize, len: usize) Error!void {
        if (offset > Backend.capacity or len > Backend.capacity - offset) return error.OutOfBounds;
        const blank: [64]u8 = @splat(0xff);
        var written: usize = 0;
        while (written < len) {
            const count = @min(blank.len, len - written);
            try self.write(offset + written, blank[0..count]);
            written += count;
        }
    }
};
