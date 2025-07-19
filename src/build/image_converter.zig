const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zigimg = @import("zigimg");
const OctTreeQuantizer = zigimg.OctTreeQuantizer;
const fs = std.fs;
const mem = std.mem;
const std = @import("std");
const lz77 = @import("lz77.zig");
const tiles = @import("tiles.zig");

pub const ImageConverterError = error{InvalidPixelData};

const GBAColor = @import("color").Color;

pub const ImageSourceTarget = struct {
    source: []const u8,
    target: []const u8,
};

pub const ImageConverter = struct {
    /// Convert images to GBA Mode 4 data. When `compress` is true, the image data
    /// is LZ77-compressed before being written to disk (palette is always raw).
    pub fn convertMode4Image(allocator: Allocator, images: []ImageSourceTarget, target_palette_file_path: []const u8, compress: bool) !void {
        var quantizer = OctTreeQuantizer.init(allocator);
        defer quantizer.deinit();

        const ImageConvertInfo = struct {
            info: ImageSourceTarget,
            image: zigimg.Image,
        };

        var image_convert_list = ArrayList(ImageConvertInfo).init(allocator);
        defer image_convert_list.deinit();

        for (images) |info| {
            const image = try zigimg.Image.fromFilePath(allocator, info.source);
            var color_it = image.iterator();

            while (color_it.next()) |pixel| {
                try quantizer.addColor(pixel.to.premultipliedAlpha());
            }

            try image_convert_list.append(.{
                .info = info,
                .image = image,
            });
        }

        var palette_storage: [256]zigimg.color.Rgba32 = undefined;
        const palette = quantizer.makePalette(256, palette_storage[0..]);

        var palette_file = try openWriteFile(target_palette_file_path);
        defer palette_file.close();

        var palette_out_stream = palette_file.writer();

        // Write palette file
        var palette_count: usize = 0;
        for (palette) |entry| {
            const gba_color = colorToGBAColor(entry);
            try palette_out_stream.writeInt(u16, @bitCast(gba_color), .little);
            palette_count += 2;
        }

        // Align palette file to a power of 4
        const diff = mem.alignForward(usize, palette_count, 4) - palette_count;
        for (0..diff) |_| {
            try palette_out_stream.writeInt(u8, 0, .little);
        }

        for (image_convert_list.items) |convert| {
            var image_file = try openWriteFile(convert.info.target);
            defer image_file.close();

            var image_out_stream = image_file.writer();

            // First collect all pixel indices in row-major order
            var pixel_indices = ArrayList(u8).init(allocator);
            defer pixel_indices.deinit();

            // Mode 4 is 240x160
            const width: usize = 240;
            const height: usize = 160;

            // Ensure image dimensions match Mode 4
            if (convert.image.width != width or convert.image.height != height) {
                return error.InvalidImageDimensions;
            }

            // Process pixels row by row
            var color_it = convert.image.iterator();
            while (color_it.next()) |pixel| {
                const raw_palette_index: usize = try quantizer.getPaletteIndex(pixel.to.premultipliedAlpha());
                const palette_index: u8 = @as(u8, @intCast(raw_palette_index));
                try pixel_indices.append(palette_index);
            }

            // Now pack pixels two per 16-bit word for Mode 4
            var packed_pixels = ArrayList(u16).init(allocator);
            defer packed_pixels.deinit();

            var i: usize = 0;
            while (i < pixel_indices.items.len) : (i += 2) {
                const lo = pixel_indices.items[i];
                const hi = if (i + 1 < pixel_indices.items.len) pixel_indices.items[i + 1] else 0;
                const packed_word = @as(u16, lo) | (@as(u16, hi) << 8);
                try packed_pixels.append(packed_word);
            }

            // Convert packed pixels to bytes for compression
            var packed_bytes = std.ArrayList(u8).init(allocator);
            defer packed_bytes.deinit();

            for (packed_pixels.items) |word| {
                try packed_bytes.append(@as(u8, @truncate(word & 0xFF))); // Low byte first
                try packed_bytes.append(@as(u8, @truncate(word >> 8))); // High byte second
            }

            if (compress) {
                const compressed = try lz77.compress(allocator, packed_bytes.items, true);
                defer allocator.free(compressed);
                try image_out_stream.writeAll(compressed);
            } else {
                // Write raw pixels
                try image_out_stream.writeAll(packed_bytes.items);

                // Align to 4-byte boundary for convenience
                const diff_raw = mem.alignForward(usize, packed_bytes.items.len, 4) - packed_bytes.items.len;
                for (0..diff_raw) |_| try image_out_stream.writeInt(u8, 0, .little);
            }

            var data = convert.image;
            data.deinit();
        }
    }

    pub fn convertTilesImage(comptime bpp: tiles.Bpp, allocator: Allocator, source_path: []const u8, target_path: []const u8, palette_path: ?[]const u8) !void {
        var palette_colors: [256]tiles.ColorRgb888 = undefined;
        var palette_slice: []tiles.ColorRgb888 = &[_]tiles.ColorRgb888{};
        const max_colors = if (bpp == .bpp_4) 16 else 256;

        if (palette_path) |p_path| {
            var palette_file = try fs.cwd().openFile(p_path, .{});
            defer palette_file.close();

            const num_colors = @divFloor(try palette_file.getEndPos(), 3);

            for (0..@min(num_colors, max_colors)) |i| {
                palette_colors[i] = .{
                    .r = try palette_file.reader().readInt(u8, .little),
                    .g = try palette_file.reader().readInt(u8, .little),
                    .b = try palette_file.reader().readInt(u8, .little),
                };
            }
            palette_slice = palette_colors[0..num_colors];
        } else {
            // Default palette for jesuMusic: black, white, black
            palette_colors[0] = .{ .r = 0, .g = 0, .b = 0 }; // Transparency
            palette_colors[1] = .{ .r = 255, .g = 255, .b = 255 }; // White
            palette_colors[2] = .{ .r = 0, .g = 0, .b = 0 }; // Black
            palette_slice = palette_colors[0..3];
        }

        try tiles.convertSaveImagePath(
            []tiles.ColorRgb888,
            source_path,
            target_path,
            .{
                .allocator = allocator,
                .bpp = bpp,
                .palette_fn = tiles.getNearestPaletteColor,
                .palette_ctx = palette_slice,
            },
        );
    }

    fn openWriteFile(path: []const u8) !fs.File {
        return fs.cwd().createFile(path, .{});
    }

    fn colorToGBAColor(color: zigimg.color.Rgba32) GBAColor {
        return .{
            .r = @truncate(color.r >> 3),
            .g = @truncate(color.g >> 3),
            .b = @truncate(color.b >> 3),
        };
    }
};
