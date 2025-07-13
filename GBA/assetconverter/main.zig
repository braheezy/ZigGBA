const std = @import("std");
const image_converter = @import("image_converter.zig");

/// Simple CLI:
///   tool [--lz77] <input_image> <output_file> ... <palette_file>
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var compress = false;
    var arg_start: usize = 1;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--lz77")) {
        compress = true;
        arg_start = 2;
    }

    // Need at least one source-target pair and a palette path
    if (args.len - arg_start < 3 or ((args.len - arg_start) % 2) != 1) {
        std.debug.print("Usage: {s} [--lz77] <input_image1> <output_file1> [<input_image2> <output_file2> ...] <palette_file>\n", .{args[0]});
        std.process.exit(1);
    }

    // Last argument is always the palette path
    const palette_path = args[args.len - 1];
    const num_images = (args.len - arg_start - 1) / 2; // -1 for palette path

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
