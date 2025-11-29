const std = @import("std");
const Image = @import("image").Image;
const Color = @import("color").Color;
const loadFromBuffer = @import("root.zig").loadFromBuffer;

// fakeIHDRUsings maps from filenames to fake IHDR "using" lines for our
// approximation to the sng command-line tool. The PNG model is that
// transparency (in the tRNS chunk) is separate to the color/grayscale/palette
// color model (in the IHDR chunk). The Go model is that the concrete
// image.Image type returned by png.Decode, such as image.RGBA (with all pixels
// having 100% alpha) or image.NRGBA, encapsulates whether or not the image has
// transparency. This map is a hack to work around the fact that the Go model
// can't otherwise discriminate PNG's "IHDR says color (with no alpha) but tRNS
// says alpha" and "IHDR says color with alpha".
var fake_ihdr_usings = std.StaticStringMap([]const u8).initComptime(.{
    .{ "ftbbn0g01", "    using grayscale;\n" },
    .{ "ftbbn0g02", "    using grayscale;\n" },
    .{ "ftbbn0g04", "    using grayscale;\n" },
    .{ "ftbbn2c16", "    using color;\n" },
    .{ "ftbgn2c16", "    using color;\n" },
    .{ "ftbrn2c08", "    using color;\n" },
    .{ "ftbwn0g16", "    using grayscale;\n" },
});
// fakegAMAs maps from filenames to fake gAMA chunks for our approximation to
// the sng command-line tool. Package png doesn't keep that metadata when
// png.Decode returns an image.Image.
var fake_gamas = std.StaticStringMap([]const u8).initComptime(.{
    .{ "ftbbn0g01", "" },
    .{ "ftbbn0g02", "gAMA {0.45455}\n" },
});
// fakebKGDs maps from filenames to fake bKGD chunks for our approximation to
// the sng command-line tool. Package png doesn't keep that metadata when
// png.Decode returns an image.Image.
var fake_bkgds = std.StaticStringMap([]const u8).initComptime(.{
    .{ "ftbbn0g01", "bKGD {gray: 0;}\n" },
    .{ "ftbbn0g02", "bKGD {gray: 0;}\n" },
    .{ "ftbbn0g04", "bKGD {gray: 0;}\n" },
    .{ "ftbbn2c16", "bKGD {red: 0;  green: 0;  blue: 65535;}\n" },
    .{ "ftbbn3p08", "bKGD {index: 245}\n" },
    .{ "ftbgn2c16", "bKGD {red: 0;  green: 65535;  blue: 0;}\n" },
    .{ "ftbgn3p08", "bKGD {index: 245}\n" },
    .{ "ftbrn2c08", "bKGD {red: 255;  green: 0;  blue: 0;}\n" },
    .{ "ftbwn0g16", "bKGD {gray: 65535;}\n" },
    .{ "ftbwn3p08", "bKGD {index: 0}\n" },
    .{ "ftbyn3p08", "bKGD {index: 245}\n" },
});

pub fn sng(writer: anytype, filename: []const u8, img: Image) !void {
    const bounds = img.bounds();
    const bit_depth: u8 = switch (img) {
        .RGBA, .NRGBA, .Gray => 8,
        .Paletted => |p| blk: {
            switch (p.palette.len) {
                0, 1, 2 => break :blk 1,
                3, 4 => break :blk 2,
                5...16 => break :blk 4,
                else => break :blk 8,
            }
        },
        else => 16,
    };

    const basename = std.fs.path.basename(filename);
    try writer.print("#SNG: from {s}\nIHDR {{\n", .{basename});
    try writer.print(
        "    width: {d}; height: {d}; bitdepth: {d};\n",
        .{ bounds.dX(), bounds.dY(), bit_depth },
    );

    const stem_name = std.fs.path.stem(filename);
    if (fake_ihdr_usings.get(stem_name)) |using| {
        try writer.print("{s}", .{using});
    } else {
        switch (img) {
            .Gray, .Gray16 => {
                try writer.print("    using grayscale;\n", .{});
            },
            .RGBA, .RGBA64 => {
                try writer.print("    using color;\n", .{});
            },
            .NRGBA, .NRGBA64 => {
                try writer.print("    using color alpha;\n", .{});
            },
            .Paletted => {
                try writer.print("    using color palette;\n", .{});
            },
            else => {
                try writer.print("unknown PNG decoder color model\n", .{});
            },
        }
    }

    try writer.print("}}\n", .{});
    if (fake_gamas.get(stem_name)) |gama| {
        try writer.print("{s}", .{gama});
    } else {
        try writer.print("gAMA {{1.0000}}\n", .{});
    }

    var use_transparent = false;
    switch (img) {
        .Paletted => |p| {
            try writer.print("PLTE {{\n", .{});
            var last_alpha: ?usize = null;

            for (p.palette, 0..) |c, i| {
                var r: u8 = 0;
                var g: u8 = 0;
                var b: u8 = 0;
                var a: u8 = 0xff;
                switch (c) {
                    .rgba => |rgba| {
                        r = rgba.r;
                        g = rgba.g;
                        b = rgba.b;
                        a = 0xff;
                    },
                    .nrgba => |nrgba| {
                        r = nrgba.r;
                        g = nrgba.g;
                        b = nrgba.b;
                        a = nrgba.a;
                    },
                    else => unreachable,
                }
                if (a != 0xff) {
                    last_alpha = i;
                }
                try writer.print("    ({d:3},{d:3},{d:3})     # rgb = (0x{x:02},0x{x:02},0x{x:02})\n", .{
                    r,
                    g,
                    b,
                    r,
                    g,
                    b,
                });
            }

            try writer.print("}}\n", .{});

            if (fake_bkgds.get(stem_name)) |bkgd| {
                try writer.print("{s}", .{bkgd});
            }
            if (last_alpha) |alpha| {
                try writer.print("tRNS {{\n", .{});
                var i: usize = 0;
                while (i <= alpha) : (i += 1) {
                    _, _, _, const color_alpha = p.palette[i].toRGBA();
                    const a = color_alpha >> 8;
                    try writer.print(" {d}", .{a});
                }
                try writer.print("}}\n", .{});
            }
        },
        else => {
            if (std.mem.startsWith(u8, stem_name, "ft")) {
                if (fake_bkgds.get(stem_name)) |bkgd| {
                    try writer.print("{s}", .{bkgd});
                }
                // We fake a tRNS chunk. The test files' grayscale and truecolor
                // transparent images all have their top left corner transparent.
                const c = img.at(0, 0);
                switch (c) {
                    .nrgba => |nrgba| {
                        if (nrgba.a == 0) {
                            use_transparent = true;
                            try writer.print("tRNS {{\n", .{});
                            if (std.mem.eql(u8, stem_name, "ftbbn0g01") or
                                std.mem.eql(u8, stem_name, "ftbbn0g02") or
                                std.mem.eql(u8, stem_name, "ftbbn0g04"))
                            {
                                // The standard image package doesn't have a "gray with
                                // alpha" type. Instead, we use an image.NRGBA.
                                try writer.print("    gray: {d};\n", .{nrgba.r});
                            } else {
                                try writer.print("    red: {d}; green: {d}; blue: {d};\n", .{ nrgba.r, nrgba.g, nrgba.b });
                            }
                            try writer.print("}}\n", .{});
                        }
                    },
                    .nrgba64 => |nrgba64| {
                        if (nrgba64.a == 0) {
                            use_transparent = true;
                            try writer.print("tRNS {{\n", .{});
                            if (std.mem.eql(u8, stem_name, "ftbwn0g16")) {
                                // The standard image package doesn't have a "gray16 with
                                // alpha" type. Instead, we use an image.NRGBA64.
                                try writer.print("    gray: {d};\n", .{nrgba64.r});
                            } else {
                                try writer.print("    red: {d}; green: {d}; blue: {d};\n", .{ nrgba64.r, nrgba64.g, nrgba64.b });
                            }
                            try writer.print("}}\n", .{});
                        }
                    },
                    else => {},
                }
            }
        },
    }
    try writer.print("IMAGE {{\n    pixels hex\n", .{});

    const dy: usize = @intCast(bounds.dY());
    const dx: usize = @intCast(bounds.dX());
    for (0..dy) |y| {
        const y_int: i32 = @intCast(y);
        switch (img) {
            .Gray => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    try writer.print("{x:02}", .{color.gray.y});
                }
            },
            .Gray16 => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    try writer.print("{x:04} ", .{color.gray16.y});
                }
            },
            .RGBA => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    try writer.print("{x:02}{x:02}{x:02} ", .{
                        color.rgba.r,
                        color.rgba.g,
                        color.rgba.b,
                    });
                }
            },
            .RGBA64 => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    try writer.print("{x:04}{x:04}{x:04} ", .{
                        color.rgba64.r,
                        color.rgba64.g,
                        color.rgba64.b,
                    });
                }
            },
            .NRGBA => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    if (std.mem.eql(u8, stem_name, "ftbbn0g01") or
                        std.mem.eql(u8, stem_name, "ftbbn0g02") or
                        std.mem.eql(u8, stem_name, "ftbbn0g04"))
                    {
                        try writer.print("{x:02}", .{color.nrgba.r});
                    } else {
                        if (use_transparent) {
                            try writer.print("{x:02}{x:02}{x:02} ", .{
                                color.nrgba.r,
                                color.nrgba.g,
                                color.nrgba.b,
                            });
                        } else {
                            try writer.print("{x:02}{x:02}{x:02}{x:02} ", .{
                                color.nrgba.r,
                                color.nrgba.g,
                                color.nrgba.b,
                                color.nrgba.a,
                            });
                        }
                    }
                }
            },
            .NRGBA64 => {
                for (0..dx) |x| {
                    const x_int: i32 = @intCast(x);
                    const color = img.at(x_int, y_int);
                    if (std.mem.eql(u8, stem_name, "ftbwn0g16")) {
                        try writer.print("{x:04} ", .{color.nrgba64.r});
                    } else {
                        if (use_transparent) {
                            try writer.print("{x:04}{x:04}{x:04} ", .{
                                color.nrgba64.r,
                                color.nrgba64.g,
                                color.nrgba64.b,
                            });
                        } else {
                            try writer.print("{x:04}{x:04}{x:04}{x:04} ", .{
                                color.nrgba64.r,
                                color.nrgba64.g,
                                color.nrgba64.b,
                                color.nrgba64.a,
                            });
                        }
                    }
                }
            },
            .Paletted => |p| {
                var b: usize = 0;
                var c: usize = 0;
                for (0..dx) |x| {
                    b = (b << @as(u6, @intCast(bit_depth))) | (p.colorIndexAt(@intCast(x), @intCast(y)));
                    c += 1;
                    if (c == 8 / bit_depth) {
                        try writer.print("{x:02}", .{b});
                        b = 0;
                        c = 0;
                    }
                }
                if (c != 0) {
                    while (c != 8 / bit_depth) {
                        b = b << @as(u6, @intCast(bit_depth));
                        c += 1;
                    }
                    try writer.print("{x:02}", .{b});
                }
            },
            else => {},
        }

        try writer.print("\n", .{});
    }
    try writer.print("}}\n", .{});
}
