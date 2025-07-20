const std = @import("std");
const image_converter = @import("image_converter.zig");
const tiles = @import("tiles.zig");

/// Simple CLI:
///   tool mode4 [--lz77] <input_image> <output_file> ... <palette_file>
///   tool tiles <input_image> <output_file> --bpp <4|8> [--palette <palette_file>]
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_with_sentinel = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_with_sentinel);

    var args_list = std.ArrayList([]const u8).init(allocator);
    defer args_list.deinit();
    for (args_with_sentinel) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage(args[0]);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "mode4")) {
        try handleMode4(allocator, args);
    } else if (std.mem.eql(u8, command, "tiles")) {
        try handleTiles(allocator, args);
    } else {
        printUsage(args[0]);
        std.process.exit(1);
    }
}

fn handleMode4(allocator: std.mem.Allocator, args: [][]const u8) !void {
    var compress = false;
    var arg_start: usize = 2;
    if (args.len > 2 and std.mem.eql(u8, args[2], "--lz77")) {
        compress = true;
        arg_start = 3;
    }

    if (args.len - arg_start < 3 or ((args.len - arg_start) % 2) != 1) {
        printUsage(args[0]);
        std.process.exit(1);
    }

    const palette_path = args[args.len - 1];
    const num_images = (args.len - arg_start - 1) / 2;

    var images = try std.ArrayList(image_converter.ImageSourceTarget).initCapacity(allocator, num_images);
    defer images.deinit();

    var i: usize = arg_start;
    while (i < args.len - 1) : (i += 2) {
        try images.append(.{
            .source = args[i],
            .target = args[i + 1],
        });
    }

    try image_converter.ImageConverter.convertMode4Image(
        allocator,
        images.items,
        palette_path,
        compress,
    );
}

fn handleTiles(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len < 5) {
        printUsage(args[0]);
        std.process.exit(1);
    }

    const input_path = args[2];
    const output_path = args[3];

    var bpp: ?tiles.Bpp = null;
    var palette_path: ?[]const u8 = null;

    var i: usize = 4;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bpp")) {
            if (i + 1 >= args.len) {
                printUsage(args[0]);
                std.process.exit(1);
            }
            const bpp_str = args[i + 1];
            if (std.mem.eql(u8, bpp_str, "4")) {
                bpp = .bpp_4;
            } else if (std.mem.eql(u8, bpp_str, "8")) {
                bpp = .bpp_8;
            } else {
                printUsage(args[0]);
                std.process.exit(1);
            }
            i += 2;
        } else if (std.mem.eql(u8, arg, "--palette")) {
            if (i + 1 >= args.len) {
                printUsage(args[0]);
                std.process.exit(1);
            }
            palette_path = args[i + 1];
            i += 2;
        } else {
            printUsage(args[0]);
            std.process.exit(1);
        }
    }

    if (bpp == null) {
        printUsage(args[0]);
        std.process.exit(1);
    }

    if (bpp) |b| {
        switch (b) {
            .bpp_4 => try image_converter.ImageConverter.convertTilesImage(
                .bpp_4,
                allocator,
                input_path,
                output_path,
                palette_path,
            ),
            .bpp_8 => try image_converter.ImageConverter.convertTilesImage(
                .bpp_8,
                allocator,
                input_path,
                output_path,
                palette_path,
            ),
        }
    } else {
        printUsage(args[0]);
        std.process.exit(1);
    }
}

fn printUsage(program: []const u8) void {
    std.debug.print(
        \\Usage: {s} <command> [options]
        \\
        \\Commands:
        \\  mode4 [--lz77] <in1> <out1> ... <palette>
        \\  tiles <in> <out> --bpp <4|8> [--palette <palette_file>]
        \\
    , .{program});
}
