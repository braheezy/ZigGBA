const std = @import("std");

/// Surface types, mirroring libtonc's ESurfaceType.
pub const SurfaceType = enum(u8) {
    none = 0,
    bmp16 = 1,
    bmp8 = 2,
    chr4r = 4,
    chr4c = 5,
    chr8 = 6,
    allocated = 0x80,
};

/// A graphics surface, mirroring libtonc's TSurface.
/// This provides an abstraction over the GBA's different video memory layouts.
pub const Surface = struct {
    data: ?*anyopaque = null,
    pitch: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    bpp: u8 = 0,
    type: SurfaceType = .none,
    pal_size: u16 = 0,
    pal_data: ?[*]u16 = null,

    /// Initializes a Surface struct. This is a port of srf_init.
    pub fn init(srf: *Surface, surface_type: SurfaceType, data_ptr: ?*anyopaque, w: u16, h: u16, bpp_in: u8, pal: ?[*]u16) void {
        srf.* = .{}; // Zero out the struct
        srf.data = data_ptr;
        srf.type = surface_type;

        var bpp_out = bpp_in;
        var pal_ptr = pal;

        switch (surface_type) {
            .chr4r => {
                bpp_out = 4;
                srf.pitch = alignPitch(w, 4) * 8;
            },
            .chr4c => {
                bpp_out = 4;
                // For column-major, pitch is based on height.
                srf.pitch = alignPitch(h, 4) * 8;
            },
            .chr8 => {
                bpp_out = 8;
                srf.pitch = alignPitch(w, 8) * 8;
            },
            .bmp8 => {
                bpp_out = 8;
                srf.pitch = alignPitch(w, bpp_out);
            },
            .bmp16 => {
                bpp_out = 16;
                srf.pitch = alignPitch(w, bpp_out);
                pal_ptr = null; // No palette for 16bpp
            },
            else => {
                srf.pitch = alignPitch(w, bpp_out);
            },
        }

        srf.width = w;
        srf.height = h;
        srf.bpp = bpp_out;

        if (pal_ptr) |p| {
            srf.pal_size = @as(u16, @intCast(1)) << @as(u4, @intCast(bpp_out));
            srf.pal_data = p;
        }
    }
};

/// Returns the word-aligned number of bytes for a scanline.
/// Port of srf_align.
fn alignPitch(width: u32, bpp: u32) u32 {
    return (width * bpp + 31) / 32 * 4;
}
