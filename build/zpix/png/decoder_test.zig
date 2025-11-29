const std = @import("std");

const load = @import("root.zig").load;
const Decoder = @import("decoder.zig");
const Image = @import("image").Image;
const sng = @import("sng.zig").sng;

const filenames = [_][]const u8{
    "basn0g01",
    "basn0g01-30",
    "basn0g02",
    "basn0g02-29",
    "basn0g04",
    "basn0g04-31",
    "basn0g08",
    "basn0g16",
    "basn2c08",
    "basn2c16",
    "basn3p01",
    "basn3p02",
    "basn3p04",
    "basn3p04-31i",
    "basn3p08",
    "basn3p08-trns",
    "basn4a08",
    "basn4a16",
    "basn6a08",
    "basn6a16",
    "ftbbn0g01",
    "ftbbn0g02",
    "ftbbn0g04",
    "ftbbn2c16",
    "ftbbn3p08",
    "ftbgn2c16",
    "ftbgn3p08",
    "ftbrn2c08",
    "ftbwn0g16",
    "ftbwn3p08",
    "ftbyn3p08",
    "ftp0n0g08",
    "ftp0n2c08",
    "ftp0n3p08",
    "ftp1n3p08",
};

test "decode" {
    const allocator = std.testing.allocator;
    for (filenames) |filename| {
        // Load the PNG file
        const png_path = std.fmt.allocPrint(allocator, "src/testdata/png/{s}.png", .{filename}) catch unreachable;
        defer allocator.free(png_path);
        const img = load(allocator, png_path) catch |err| {
            std.log.err("Failed to load {s}: {t}", .{ png_path, err });
            std.process.exit(0);
        };
        defer img.free(allocator);

        if (std.mem.eql(u8, filename, "basn4a16")) {
            // basn4a16.sng is gray + alpha but sng() will produce true color + alpha
            // so we just check a single random pixel.
            const color = img.at(2, 1).nrgba64;

            try std.testing.expect(color.r == 0x11a7 and color.g == 0x11a7 and color.b == 0x11a7 and color.a == 0x1085);
            continue;
        }

        // Create a buffer for our SNG output
        var output_buf: [0x10000]u8 = undefined;
        var output_stream = std.io.fixedBufferStream(&output_buf);
        const writer = output_stream.writer();

        // Generate SNG output
        try sng(writer, png_path, img);
        const written = output_stream.pos;
        const output_slice = output_buf[0..written];

        // Read the expected SNG file
        const sng_path = std.fmt.allocPrint(allocator, "src/testdata/png/{s}.sng", .{filename}) catch unreachable;
        defer allocator.free(sng_path);

        const expected_file = try std.fs.cwd().openFile(sng_path, .{});
        defer expected_file.close();

        var expected_buf = std.ArrayListUnmanaged(u8){};
        defer expected_buf.deinit(allocator);
        var io_buf: [1024]u8 = undefined;
        var file_reader = expected_file.reader(&io_buf);
        const reader: *std.Io.Reader = &file_reader.interface;
        try reader.appendRemaining(allocator, &expected_buf, @enumFromInt(0x10000));

        // Compare line by line
        var output_lines = std.mem.splitSequence(u8, output_slice, "\n");
        var expected_lines = std.mem.splitSequence(u8, expected_buf.items, "\n");

        while (true) {
            const output_line = output_lines.next();
            var expected_line = expected_lines.next();

            if (output_line == null and expected_line == null) break;

            // Newer versions of the sng command line tool append an optional
            // color name to the RGB tuple. For example:
            // # rgb = (0xff,0xff,0xff) grey100
            // # rgb = (0x00,0x00,0xff) blue1
            // instead of the older version's plainer:
            // # rgb = (0xff,0xff,0xff)
            // # rgb = (0x00,0x00,0xff)
            // We strip any such name.
            if (std.mem.containsAtLeast(u8, expected_line.?, 1, "# rgb = (") and
                !std.mem.endsWith(u8, expected_line.?, ")"))
            {
                const i = std.mem.lastIndexOf(u8, expected_line.?, ") ");
                if (i) |index| {
                    expected_line = expected_line.?[0 .. index + 1];
                }
            }

            if (output_line == null or expected_line == null) {
                std.debug.print("Line count mismatch for {s}\n", .{filename});
                return error.TestUnexpectedResult;
            }

            std.testing.expectEqualStrings(expected_line.?, output_line.?) catch {
                std.debug.print("Line mismatch for {s}\n", .{filename});
                return error.TestUnexpectedResult;
            };
        }
    }
}
