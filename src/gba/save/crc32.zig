//! CRC32 used to detect damaged save records.

/// Incremental IEEE CRC32 implementation. It intentionally avoids a lookup
/// table so the save subsystem has no static 1 KiB table cost.
pub const Crc32 = struct {
    value: u32 = 0xffff_ffff,

    /// Incorporate one byte.
    pub fn updateByte(self: *Crc32, byte: u8) void {
        var value = self.value ^ byte;
        for (0..8) |_| {
            value = (value >> 1) ^ (if ((value & 1) != 0) @as(u32, 0xedb8_8320) else 0);
        }
        self.value = value;
    }

    /// Incorporate a byte slice.
    pub fn update(self: *Crc32, bytes: []const u8) void {
        for (bytes) |byte| self.updateByte(byte);
    }

    /// Finish the checksum.
    pub fn final(self: Crc32) u32 {
        return self.value ^ 0xffff_ffff;
    }
};

/// Calculate an IEEE CRC32 checksum.
pub fn checksum(bytes: []const u8) u32 {
    var crc: Crc32 = .{};
    crc.update(bytes);
    return crc.final();
}

test "CRC32 matches the standard check value" {
    const std = @import("std");
    try std.testing.expectEqual(0xcbf4_3926, checksum("123456789"));
}
