const std = @import("std");
const image_converter = @import("image_converter.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Need at least program name, one source-target pair, and palette path
    if (args.len < 4 or args.len % 2 != 0) {
        std.debug.print("Usage: {s} <input_image1> <output_agi1> [<input_image2> <output_agi2> ...] <palette_agp>\n", .{args[0]});
        std.process.exit(1);
    }

    // Last argument is always the palette path
    const palette_path = args[args.len - 1];
    const num_images = (args.len - 2) / 2; // -2 for program name and palette path

    var images = try std.ArrayList(image_converter.ImageSourceTarget).initCapacity(allocator, num_images);
    defer images.deinit();

    var i: usize = 1;
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
    );
}
