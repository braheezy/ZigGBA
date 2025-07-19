const gba = @import("gba.zig");

/// Convenience wrappers around BIOS decompression SWIs that accept the data
/// as a plain `[]const u8` slice produced by the asset-converter.
/// The slice *must* begin with the 4-byte GBA decompression header.
pub fn lz77ToVRAM(data: []const u8, dest: [*]volatile u16) void {
    const hdr: *const gba.bios.DecompressionHeader = @ptrCast(@alignCast(data.ptr));
    gba.bios.decompressLZ77VRAM(hdr, @volatileCast(dest));
}

pub fn lz77ToWRAM(data: []const u8, dest: *anyopaque) void {
    const hdr: *const gba.bios.DecompressionHeader = @ptrCast(@alignCast(data.ptr));
    gba.bios.decompressLZ77WRAM(hdr, dest);
}

pub fn runLengthToVRAM(data: []const u8, dest: *anyopaque) void {
    const hdr: *const gba.bios.DecompressionHeader = @ptrCast(@alignCast(data.ptr));
    gba.bios.decompressRunLengthVRAM(hdr, dest);
}

pub fn runLengthToWRAM(data: []const u8, dest: *anyopaque) void {
    const hdr: *const gba.bios.DecompressionHeader = @ptrCast(@alignCast(data.ptr));
    gba.bios.decompressRunLengthWRAM(hdr, dest);
}
