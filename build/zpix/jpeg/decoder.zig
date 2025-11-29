//! JPEG Decoder module.
//! JPEG is defined in ITU-T T.81: https://www.w3.org/Graphics/JPEG/itu-t81.pdf.
const std = @import("std");
const image = @import("../image/root.zig");
const idct = @import("idct.zig");
const HuffTable = @import("HuffTable.zig");

/// JPEG-defined constants.
const max_components = 4;
const max_tc = 1;
const max_th = 3;
const max_tq = 3;
const ac_table = 1;
const dc_table = 0;

/// [Table B.1] Marker code assignments
pub const Marker = enum(u8) {
    // Start Of Frame (Baseline Sequential).
    sof0 = 0xc0,
    // Start Of Frame (Extended Sequential).
    sof1 = 0xc1,
    // Start Of Frame (Progressive).
    sof2 = 0xc2,
    // Define Huffman Table.
    dht = 0xc4,
    // ReSTart (0).
    rst0 = 0xd0,
    // ReSTart (7).
    rst7 = 0xd7,
    // Start Of Image.
    soi = 0xd8,
    // End Of Image.
    eoi = 0xd9,
    // Start Of Scan.
    sos = 0xda,
    // Define Quantization Table.
    dqt = 0xdb,
    // Define Restart Interval.
    dri = 0xdd,
    // COMment
    com = 0xfe,
    // "APPlication specific" markers aren't part of the JPEG spec per se,
    // but in practice, their use is described at
    // https://www.sno.phy.queensu.ca/~phil/exiftool/TagNames/JPEG.html
    app0 = 0xe0,
    app14 = 0xee,
    app15 = 0xef,
    _,
};

/// See https://www.sno.phy.queensu.ca/~phil/exiftool/TagNames/JPEG.html#Adobe
pub const AdobeTransform = enum {
    unknown,
    y_cb_cr,
    y_cb_cr_k,
};

/// Component specification, specified in section B.2.2.
const Component = struct {
    // Horizontal sampling factor.
    h: i32 = 0,
    // Vertical sampling factor.
    v: i32 = 0,
    // Component identifier.
    id: u8 = 0,
    // Quantization table destination selector.
    tq: u8 = 0,
};

/// unzig maps from the zig-zag ordering to the natural ordering. For example,
/// unzig[3] is the column and row of the fourth element in zig-zag order. The
/// value is 16, which means first column (16%8 == 0) and third row (16/8 == 2).
const unzig: [idct.block_size]u8 = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Main decoder struct.
pub const Decoder = @This();

/// Bits holds the unprocessed bits that have been taken from the byte-stream.
/// The n least significant bits of a form the unread bits, to be read in MSB to
/// LSB order.
const Bits = struct {
    // accumulator
    a: u32 = 0,
    // mask.  m==1<<(n-1) when n>0, with m==0 when n==0.
    m: u32 = 0,
    // the number of unread bits in a.
    n: i32 = 0,
};

// memory allocator
al: std.mem.Allocator,
// reader into provided JPEG data (new std.Io API)
r: *std.Io.Reader,
bits: Bits,

// bytes is a byte buffer that it is able to unread more than 1 byte,
// due to byte stuffing, as specified in section F.1.2.3.
bytes: struct {
    // buffer[i:j] are the buffered bytes read from the underlying
    // `r` reader that haven't yet been passed further on.
    buffer: [4096]u8,
    i: usize = 0,
    j: usize = 0,
    // num_unreadable is the number of bytes to back up i after
    // overshooting. It can be 0, 1 or 2.
    num_unreadable: usize = 0,
},
// image dimensions
width: u32 = 0,
height: u32 = 0,

// destination image data
gray_img: ?image.GrayImage = null,
ycbcr_img: ?image.YCbCrImage = null,
img: ?image.Image = null,
black_pixels: ?[]u8 = null,
black_stride: usize = 0,
previous_gray_all_pixels: ?[]u8 = null,

restart_interval: u16 = 0,
num_components: u8 = 0,

// As per section 4.5, there are four modes of operation (selected by the
// SOF? markers): sequential DCT, progressive DCT, lossless and
// hierarchical, although this implementation does not support the latter
// two non-DCT modes. Sequential DCT is further split into baseline and
// extended, as per section 4.11.
baseline: bool = false,
progressive: bool = false,

jfif: bool = false,
adobe_transform_valid: bool = false,
adobe_transform: AdobeTransform = .unknown,
// End-of-Band run, specified in section G.1.2.2.
eob_run: u16 = 0,

component: [max_components]Component,
// Saved state between progressive-mode scans.
progressive_coefficients: [max_components]?[]idct.Block,
huff: [max_tc + 1][max_th + 1]HuffTable,
// Quantization table, in zig-zag order.
quant: [max_tq + 1]idct.Block,
// preallocated temp buffer to reuse while reading
tmp: [2 * idct.block_size]u8 = [_]u8{0} ** (2 * idct.block_size),

pub fn decode(al: std.mem.Allocator, r: *std.Io.Reader) !image.Image {
    var d = Decoder{
        .al = al,
        .r = r,
        .bytes = .{ .buffer = [_]u8{0} ** 4096 },
        .component = [_]Component{.{}} ** max_components,
        .huff = undefined,
        .quant = undefined,
        .bits = undefined,
        .progressive_coefficients = [_]?[]idct.Block{ null, null, null, null },
    };

    defer {
        for (d.progressive_coefficients) |slice_opt| {
            if (slice_opt) |slice| {
                d.al.free(slice);
            }
        }
    }

    return try d.decodeInner(false);
}

pub fn decodeConfig(r: *std.Io.Reader) !image.Config {
    var d = Decoder{
        .al = undefined,
        .r = r,
        .bytes = .{ .buffer = [_]u8{0} ** 4096 },
        .component = [_]Component{.{}} ** max_components,
        .huff = undefined,
        .quant = undefined,
        .bits = undefined,
        .progressive_coefficients = [_]?[]idct.Block{ null, null, null, null },
    };
    _ = d.decodeInner(true) catch |err| {
        if (err != error.ConfigOnly) {
            return err;
        }
    };

    return switch (d.num_components) {
        1 => {
            return image.Config{
                .width = d.width,
                .height = d.height,
                .color_model = .Gray,
            };
        },
        3 => {
            return image.Config{
                .width = d.width,
                .height = d.height,
                .color_model = .YCbCr,
            };
        },
        4 => image.Config{
            .width = d.width,
            .height = d.height,
            // TODO: Support CMYK
            .color_model = .YCbCr,
        },
        else => error.InvalidSOIMarker,
    };
}

fn decodeInner(self: *Decoder, config_only: bool) !image.Image {
    errdefer {
        // If there's errors during decoding, free allocated memory
        // to prevent leaks.
        if (self.gray_img) |gray_img| {
            self.al.free(gray_img.pixels);
        }
        if (self.ycbcr_img) |ycbcr_img| {
            self.al.free(ycbcr_img.pixels);
        }

        if (self.black_pixels != null) {
            self.al.free(self.black_pixels.?);
        }
    }

    try self.readFull(self.tmp[0..2]);

    // Check for the Start of Image marker.
    if (self.tmp[0] != 0xFF or self.tmp[1] != @intFromEnum(Marker.soi)) {
        return error.InvalidSOIMarker;
    }

    // Process the remaining segments until the End Of Image marker.
    while (true) {
        try self.readFull(self.tmp[0..2]);
        while (self.tmp[0] != 0xff) {
            // Strictly speaking, this is a format error. However, libjpeg is
            // liberal in what it accepts. As of version 9, next_marker in
            // jdmarker.c treats this as a warning (JWRN_EXTRANEOUS_DATA) and
            // continues to decode the stream. Even before next_marker sees
            // extraneous data, jpeg_fill_bit_buffer in jdhuff.c reads as many
            // bytes as it can, possibly past the end of a scan's data. It
            // effectively puts back any markers that it overscanned (e.g. an
            // "\xff\xd9" EOI marker), but it does not put back non-marker data,
            // and thus it can silently ignore a small number of extraneous
            // non-marker bytes before next_marker has a chance to see them (and
            // print a warning).
            //
            // We are therefore also liberal in what we accept. Extraneous data
            // is silently ignored.
            //
            // This is similar to, but not exactly the same as, the restart
            // mechanism within a scan (the RST[0-7] markers).
            //
            // Note that extraneous 0xff bytes in e.g. SOS data are escaped as
            // "\xff\x00", and so are detected a little further down below.
            self.tmp[0] = self.tmp[1];
            self.tmp[1] = try self.readByte();
        }

        var marker = self.tmp[1];

        if (marker == 0) {
            // Treat "\xff\x00" as extraneous data.
            continue;
        }
        while (marker == 0xff) {
            // Section B.1.1.2 says, "Any marker may optionally be preceded by any
            // number of fill bytes, which are bytes assigned code X'FF'".
            marker = try self.readByte();
        }
        if (marker == @intFromEnum(Marker.eoi)) {
            // Done!
            break;
        }
        if (@intFromEnum(Marker.rst0) <= marker and marker <= @intFromEnum(Marker.rst7)) {
            // Figures B.2 and B.16 of the specification suggest that restart markers should
            // only occur between Entropy Coded Segments and not after the final ECS.
            // However, some encoders may generate incorrect JPEGs with a final restart
            // marker. That restart marker will be seen here instead of inside the processSOS
            // method, and is ignored as a harmless error. Restart markers have no extra data,
            // so we check for this before we read the 16-bit length of the segment.
            continue;
        }

        // Read the 16-bit length of the segment. The value includes the 2 bytes for the
        // length itself, so we subtract 2 to get the number of remaining bytes.
        try self.readFull(self.tmp[0..2]);
        var n = @as(i32, self.tmp[0]) << 8;
        n = n + @as(i32, self.tmp[1]) - 2;
        if (n < 0) {
            return error.ShortSegmentLength;
        }

        const marker_enum: Marker = @enumFromInt(marker);
        switch (marker_enum) {
            .sof0, .sof1, .sof2 => {
                self.baseline = marker_enum == Marker.sof0;
                self.progressive = marker_enum == Marker.sof2;
                try self.processSof(n);
                if (config_only and self.jfif) {
                    return error.ConfigOnly;
                }
            },
            .dqt => {
                if (config_only) {
                    try self.ignore(n);
                } else {
                    try self.processDqt(n);
                }
            },
            .dri => {
                if (config_only) {
                    try self.ignore(n);
                } else {
                    try self.processDri(n);
                }
            },
            .dht => {
                if (config_only) {
                    try self.ignore(n);
                } else {
                    try self.processDht(n);
                }
            },
            .sos => {
                if (config_only) {
                    return error.ConfigOnly;
                }
                try self.processSos(n);
            },
            .app0 => try self.processApp0Marker(n),
            .app14 => try self.processApp14Marker(n),
            else => {
                if (@intFromEnum(Marker.app0) <= marker and marker <= @intFromEnum(Marker.app15) or marker == @intFromEnum(Marker.com)) {
                    try self.ignore(n);
                } else if (marker < 0xc0) {
                    // See Table B.1 "Marker code assignments".
                    return error.UnknownMarker;
                } else {
                    return error.UnsupportedMarker;
                }
            },
        }
    }

    if (self.progressive) {
        try self.reconstructProgressiveImage();
    }

    if (self.gray_img) |gray_img| {
        return image.Image{ .Gray = gray_img };
    } else if (self.ycbcr_img) |ycbcr_img| {
        if (self.black_pixels) |_| {
            return self.applyBlack();
        } else if (self.isRgb()) {
            return try self.convertToRGB();
        }
        return image.Image{ .YCbCr = ycbcr_img };
    }

    return error.MissingSosMarker;
}

// ignore ignores the next n bytes.
fn ignore(self: *Decoder, n: i32) !void {
    var local_n = n;
    // Unread the overshot bytes, if any.
    if (self.bytes.num_unreadable > 0) {
        if (self.bits.n >= 8) {
            self.unreadByteStuffedByte();
        }
        self.bytes.num_unreadable = 0;
    }

    while (true) {
        var remaining_bytes = self.bytes.j - self.bytes.i;
        if (remaining_bytes > local_n) {
            remaining_bytes = @intCast(local_n);
        }
        self.bytes.i += remaining_bytes;
        local_n -= @intCast(remaining_bytes);
        if (local_n == 0) {
            break;
        }
        try self.fill();
    }
}

// readByte returns the next byte, whether buffered or not buffered. It does
// not care about byte stuffing.
fn readByte(self: *Decoder) !u8 {
    while (self.bytes.i == self.bytes.j) {
        try self.fill();
    }
    const x = self.bytes.buffer[self.bytes.i];
    self.bytes.i += 1;
    self.bytes.num_unreadable = 0;
    return x;
}

// readFull reads exactly len(p) bytes into p. It does not care about byte
// stuffing.
fn readFull(self: *Decoder, p: []u8) !void {
    var offset: usize = 0;

    // Unread the overshot bytes, if any.
    if (self.bytes.num_unreadable > 0) {
        if (self.bits.n >= 8) {
            self.unreadByteStuffedByte();
        }
        self.bytes.num_unreadable = 0;
    }

    while (offset < p.len) {
        // Calculate how much can be copied from the internal buffer.
        const available = self.bytes.j - self.bytes.i;
        const to_copy = @min(available, p.len - offset);

        // Copy data from the internal buffer to the output buffer.
        @memcpy(p[offset .. offset + to_copy], self.bytes.buffer[self.bytes.i .. self.bytes.i + to_copy]);
        self.bytes.i += to_copy;
        offset += to_copy;

        // If the output buffer is fully written, we're done.
        if (offset == p.len) {
            break;
        }

        // Refill the internal buffer if it's exhausted.
        try self.fill();
    }
}

// fill fills up the self.bytes.buffer from the underlying reader. It
// should only be called when there are no unread bytes in self.bytes.
fn fill(self: *Decoder) !void {
    // Ensure all bytes have been read before refilling.
    if (self.bytes.i != self.bytes.j) {
        @panic("Decoder.fill() called when unread bytes exist");
    }

    // Move the last 2 bytes to the start of the buffer, in case we need
    // to call unreadByteStuffedByte.
    if (self.bytes.j > 2) {
        self.bytes.buffer[0] = self.bytes.buffer[self.bytes.j - 2];
        self.bytes.buffer[1] = self.bytes.buffer[self.bytes.j - 1];
        self.bytes.i = 2;
        self.bytes.j = 2;
    } else {
        self.bytes.i = 0;
        self.bytes.j = 0;
    }

    // Fill the rest of the buffer with a single non-blocking read.
    const n = self.r.readSliceShort(self.bytes.buffer[self.bytes.j..]) catch |err| {
        if (err == error.EndOfStream) return error.UnexpectedEof;
        return err;
    };
    self.bytes.j += n;
    if (n == 0) return error.UnexpectedEof;
}

// unreadByteStuffedByte undoes the most recent readByteStuffedByte call,
// giving a byte of data back from self.bits to self.bytes. The Huffman look-up table
// requires at least 8 bits for look-up, which means that Huffman decoding can
// sometimes overshoot and read one or two too many bytes. Two-byte overshoot
// can happen when expecting to read a 0xff 0x00 byte-stuffed byte.
fn unreadByteStuffedByte(self: *Decoder) void {
    self.bytes.i -= self.bytes.num_unreadable;
    self.bytes.num_unreadable = 0;
    if (self.bits.n >= 8) {
        self.bits.a >>= 8;
        self.bits.n -= 8;
        self.bits.m >>= 8;
    }
}

// covered in section B.2.2
fn processSof(self: *Decoder, n: i32) !void {
    if (self.num_components != 0) {
        return error.MultipleSofMarkers;
    }

    self.num_components = switch (n) {
        // grayscale image
        6 + 3 * 1 => 1,
        // YCbCr or RGB image
        6 + 3 * 3 => 3,
        // CMYK image
        6 + 3 * 4 => 4,
        else => return error.NumberComponents,
    };

    try self.readFull(self.tmp[0..@intCast(n)]);

    // only support 8-bit precision
    if (self.tmp[0] != 8) {
        return error.Precision;
    }

    self.height = @as(u32, self.tmp[1]) << 8;
    self.height += @as(u32, self.tmp[2]);
    self.width = @as(u32, self.tmp[3]) << 8;
    self.width += @as(u32, self.tmp[4]);

    if (self.tmp[5] != self.num_components) {
        return error.SofWrongLength;
    }

    for (0..self.num_components) |i| {
        self.component[i].id = self.tmp[6 + 3 * i];

        // Section B.2.2 states that "the value of C_i shall be different from
        // the values of C_1 through C_(i-1)".
        for (0..i) |j| {
            if (self.component[i].id == self.component[j].id) {
                return error.RepeatedComponentIdentifier;
            }
        }

        self.component[i].tq = self.tmp[8 + 3 * i];
        if (self.component[i].tq > max_tq) {
            return error.BadTqValue;
        }

        const hv_sampling = self.tmp[7 + 3 * i];
        var h = hv_sampling >> 4;
        var v = hv_sampling & 0x0f;
        if (h < 1 or 4 < h or v < 1 or 4 < v) {
            return error.LumaChromaSubSamplingRatio;
        }
        if (h == 3 or v == 3) {
            return error.LumaChromaSubSamplingRatio;
        }
        switch (self.num_components) {
            1 => {
                // If a JPEG image has only one component, section A.2 says "this data
                // is non-interleaved by definition" and section A.2.2 says "[in this
                // case...] the order of data units within a scan shall be left-to-right
                // and top-to-bottom... regardless of the values of H_1 and V_1". Section
                // 4.8.2 also says "[for non-interleaved data], the MCU is defined to be
                // one data unit". Similarly, section A.1.1 explains that it is the ratio
                // of H_i to max_j(H_j) that matters, and similarly for V. For grayscale
                // images, H_1 is the maximum H_j for all components j, so that ratio is
                // always 1. The component's (h, v) is effectively always (1, 1): even if
                // the nominal (h, v) is (2, 1), a 20x5 image is encoded in three 8x8
                // MCUs, not two 16x8 MCUs.
                h = 1;
                v = 1;
            },

            3 => {

                // For YCbCr images, we only support 4:4:4, 4:4:0, 4:2:2, 4:2:0,
                // 4:1:1 or 4:1:0 chroma subsampling ratios. This implies that the
                // (h, v) values for the Y component are either (1, 1), (1, 2),
                // (2, 1), (2, 2), (4, 1) or (4, 2), and the Y component's values
                // must be a multiple of the Cb and Cr component's values. We also
                // assume that the two chroma components have the same subsampling
                // ratio.
                switch (i) {
                    // Y
                    0 => {
                        // We have already verified, above, that h and v are both
                        // either 1, 2 or 4, so invalid (h, v) combinations are those
                        // with v == 4.
                        if (v == 4) return error.LumaChromaSubSamplingRatio;
                    },
                    // Cb
                    1 => {
                        if (@mod(self.component[0].h, h) != 0 or @mod(self.component[0].v, v) != 0) {
                            return error.LumaChromaSubSamplingRatio;
                        }
                    },
                    // Cr
                    2 => {
                        if (self.component[1].h != h or self.component[1].v != v) {
                            return error.LumaChromaSubSamplingRatio;
                        }
                    },
                    else => return error.NumberComponents,
                }
            },
            4 => {
                // For 4-component images (either CMYK or YCbCrK), we only support two
                // hv vectors: [0x11 0x11 0x11 0x11] and [0x22 0x11 0x11 0x22].
                // Theoretically, 4-component JPEG images could mix and match hv values
                // but in practice, those two combinations are the only ones in use,
                // and it simplifies the applyBlack code below if we can assume that:
                //  - for CMYK, the C and K channels have full samples, and if the M
                //    and Y channels subsample, they subsample both horizontally and
                //    vertically.
                //  - for YCbCrK, the Y and K channels have full samples.
                switch (i) {
                    0 => if (hv_sampling != 0x11 and hv_sampling != 0x22) return error.LumaChromaSubSamplingRatio,
                    1, 2 => if (hv_sampling != 0x11) return error.LumaChromaSubSamplingRatio,
                    3 => if (self.component[0].h != h or self.component[0].v != v) return error.LumaChromaSubSamplingRatio,
                    else => return error.NumberComponents,
                }
            },
            else => return error.NumberComponents,
        }

        self.component[i].h = h;
        self.component[i].v = v;
    }
}

// Specified in section B.2.4.4.
fn processDri(self: *Decoder, n: i32) !void {
    if (n != 2) {
        return error.DriWrongLength;
    }
    try self.readFull(self.tmp[0..2]);
    self.restart_interval = (@as(u16, @as(u16, self.tmp[0]) << 8)) + @as(u16, self.tmp[1]);
}
// covered in section B.2.4.1
fn processDqt(self: *Decoder, n: i32) !void {
    var local_n = n;
    loop: while (local_n > 0) {
        local_n -= 1;
        const quant_info = try self.readByte();
        const tq = quant_info & 0x0f;
        if (tq > max_tq) {
            return error.BadTqValue;
        }
        switch (quant_info >> 4) {
            0 => {
                if (local_n < idct.block_size) {
                    break :loop;
                }
                local_n -= idct.block_size;
                try self.readFull(self.tmp[0..idct.block_size]);
                for (self.quant[tq], 0..) |_, i| {
                    self.quant[tq][i] = @intCast(self.tmp[i]);
                }
            },
            1 => {
                if (local_n < 2 * idct.block_size) {
                    break :loop;
                }
                local_n -= 2 * idct.block_size;
                try self.readFull(self.tmp[0 .. 2 * idct.block_size]);
                for (self.quant[tq], 0..) |_, i| {
                    const j = @as(i32, self.tmp[2 * i]) << 8;
                    self.quant[tq][i] = j | self.tmp[2 * i + 1];
                }
            },
            else => return error.BadPqValue,
        }
    }
    if (local_n != 0) {
        return error.DqtWrongLength;
    }
}

fn processApp0Marker(self: *Decoder, n: i32) !void {
    if (n < 5) {
        return self.ignore(n);
    }
    try self.readFull(self.tmp[0..5]);

    var local_n = n;
    local_n -= 5;

    self.jfif = self.tmp[0] == 'J' and self.tmp[1] == 'F' and self.tmp[2] == 'I' and self.tmp[3] == 'F' and self.tmp[4] == '\x00';

    if (n > 0) return self.ignore(local_n);
}

fn processApp14Marker(self: *Decoder, n: i32) !void {
    if (n < 12) {
        return self.ignore(n);
    }
    try self.readFull(self.tmp[0..12]);

    var local_n = n;
    local_n -= 12;

    if (self.tmp[0] == 'A' and self.tmp[1] == 'd' and self.tmp[2] == 'o' and self.tmp[3] == 'b' and self.tmp[4] == 'e') {
        self.adobe_transform_valid = true;
        self.adobe_transform = @enumFromInt(self.tmp[11]);
    }

    if (n > 0) return self.ignore(local_n);
}

fn isRgb(self: *Decoder) bool {
    if (self.jfif) return false;

    if (self.adobe_transform_valid and self.adobe_transform == .unknown) {
        // https://www.sno.phy.queensu.ca/~phil/exiftool/TagNames/JPEG.html#Adobe
        // says that 0 means Unknown (and in practice RGB) and 1 means YCbCr.
        return true;
    }

    return self.component[0].id == 'R' and self.component[1].id == 'G' and self.component[2].id == 'B';
}

// readByteStuffedByte is like readByte but is for byte-stuffed Huffman data.
fn readByteStuffedByte(self: *Decoder) !u8 {
    // Take the fast path if there are at least two bytes in the buffer.
    if (self.bytes.i + 2 <= self.bytes.j) {
        const x = self.bytes.buffer[self.bytes.i];
        self.bytes.i += 1;
        self.bytes.num_unreadable = 1;

        if (x != 0xff) {
            return x;
        }

        if (self.bytes.buffer[self.bytes.i] != 0x00) {
            return error.MissingFF00;
        }

        self.bytes.i += 1;
        self.bytes.num_unreadable = 2;
        return 0xff;
    }

    self.bytes.num_unreadable = 0;

    var x = try self.readByte();
    self.bytes.num_unreadable = 1;

    if (x != 0xff) {
        return x;
    }

    x = try self.readByte();
    self.bytes.num_unreadable = 2;

    if (x != 0x00) {
        return error.MissingFF00;
    }

    return 0xff;
}

pub fn convertToRGB(self: *Decoder) !image.Image {
    // Ensure YCbCr image before proceeding
    const ycbcr_img = if (self.ycbcr_img) |img| img else return error.InvalidImageType;

    // We're going to allocate new memory for the CMYK image, so we can free the
    // old image memory
    defer {
        if (self.ycbcr_img) |i| {
            self.al.free(i.pixels);
        }
    }

    const c_scale: usize = @intCast(@divTrunc(self.component[0].h, self.component[1].h));
    const bounds = ycbcr_img.bounds();
    var img = try image.RGBAImage.init(self.al, bounds);

    var y = bounds.min.y;
    while (y < bounds.max.y) : (y += 1) {
        const po: usize = @intCast(img.pixOffset(bounds.min.x, y));
        const yo: usize = @intCast(ycbcr_img.yOffset(bounds.min.x, y));
        const co: usize = @intCast(ycbcr_img.cOffset(bounds.min.x, y));

        var i: usize = 0;
        const i_max = bounds.max.x - bounds.min.x;
        while (i < i_max) : (i += 1) {
            img.pixels[po + 4 * i + 0] = ycbcr_img.y[yo + i];
            img.pixels[po + 4 * i + 1] = ycbcr_img.cb[co + i / c_scale];
            img.pixels[po + 4 * i + 2] = ycbcr_img.cr[co + i / c_scale];
            img.pixels[po + 4 * i + 3] = 255;
        }
    }
    return .{ .RGBA = img };
}

/// applyBlack combines self.ycbcr_img and self.black_pixels into a CMYK image.
/// The formula used depends on whether the JPEG image is stored as CMYK or YCbCrK,
/// indicated by the APP14 (Adobe) metadata.
///
/// Adobe CMYK JPEG images are inverted, where 255 means no ink instead of full ink,
/// so we apply "v = 255 - v" at various points. Note that a double inversion is
/// a no-op, so inversions might be implicit in the code below.
pub fn applyBlack(self: *Decoder) !image.Image {
    if (!self.adobe_transform_valid) {
        return error.UnsupportedColorModel;
    }

    // We're going to allocate new memory for the CMYK image, so we can free the
    // old image memory
    defer {
        if (self.black_pixels) |black_pixels| {
            self.al.free(black_pixels);
        }

        if (self.ycbcr_img) |ycbcr_img| {
            self.al.free(ycbcr_img.pixels);
        }
    }

    // If the 4-component JPEG image isn't explicitly marked as "Unknown (RGB or CMYK)"
    // we assume that it is YCbCrK. This matches libjpeg's behavior.
    if (self.adobe_transform != .unknown) {
        // Convert the YCbCr part of the YCbCrK to RGB, invert the RGB to get CMY,
        // and patch in the original K. The RGB to CMY inversion cancels out the
        // 'Adobe inversion' described above, so in practice, only the fourth channel (black) is inverted.
        const bounds = self.ycbcr_img.?.bounds();
        var img = try image.RGBAImage.init(self.al, bounds);

        if (self.ycbcr_img) |ycbcr_img| {
            _ = try image.util.drawYCbCr(&img, bounds, ycbcr_img, bounds.min);
        }

        var i_base: usize = 0;
        var y: i32 = bounds.min.y;
        while (y < bounds.max.y) {
            var i: usize = i_base + 3;
            var x: i32 = bounds.min.x;
            while (x < bounds.max.x) {
                const y_delta: usize = @intCast(y - bounds.min.y);
                const x_delta: usize = @intCast(x - bounds.min.x);

                img.pixels[i] = 255 - self.black_pixels.?[y_delta * self.black_stride + x_delta];

                x += 1;
                i += 4;
            }

            y += 1;
            i_base += img.stride;
        }

        var cmyk_img = image.CMYKImage{};
        cmyk_img.pixels = img.pixels;
        cmyk_img.stride = img.stride;
        cmyk_img.rect = img.rect;
        return .{ .CMYK = cmyk_img };
    }

    // The first three channels (cyan, magenta, yellow) of the CMYK were decoded into self.ycbcr_img,
    // but each channel was decoded into a separate slice, and some channels may be subsampled.
    // We interleave the separate channels into an image.CMYK's single []u8 slice containing
    // 4 contiguous bytes per pixel.
    const bounds = self.ycbcr_img.?.bounds();
    var img = try image.CMYKImage.init(self.al, bounds);

    const Translations = struct {
        src: []u8,
        stride: usize,
    };
    var translations: [4]Translations = undefined;

    if (self.ycbcr_img) |i| {
        translations = [_]Translations{
            .{ .src = i.y, .stride = i.y_stride },
            .{ .src = i.cb, .stride = i.c_stride },
            .{ .src = i.cr, .stride = i.c_stride },
            .{ .src = self.black_pixels.?, .stride = self.black_stride },
        };
    } else {
        unreachable;
    }

    for (translations, 0..) |translation, t| {
        const subsample = self.component[t].h != self.component[0].h or self.component[t].v != self.component[0].v;

        var i_base: usize = 0;
        var y: i32 = bounds.min.y;
        while (y < bounds.max.y) {
            var sy: usize = @intCast(y - bounds.min.y);
            if (subsample) {
                sy >>= 1;
            }

            var i: usize = i_base + t;
            var x: i32 = bounds.min.x;
            while (x < bounds.max.x) {
                var sx: usize = @intCast(x - bounds.min.x);
                if (subsample) {
                    sx >>= 1;
                }
                img.pixels[i] = 255 - translation.src[sy * translation.stride + sx];

                i += 4;
                x += 1;
            }

            y += 1;
            i_base += img.stride;
        }
    }

    return .{ .CMYK = img };
}

//===================================//
// # Huffman Processing
//===================================//
// decodeHuffman returns the next Huffman-coded value from the bit-stream,
// decoded according to h.
fn decodeHuffman(self: *Decoder, huff_table: *HuffTable) !u8 {
    if (huff_table.num_codes == 0) {
        return error.UninitializedHuffmanTable;
    }

    // Fast path: Check if enough bits are available.
    const goto_slow_path = if (self.bits.n < 8) blk: {
        self.ensureNBits(8) catch |err| {
            if (err != error.MissingFF00 and err != error.ShortHuffmanData) {
                return err;
            }
            // There are no more bytes of data in this segment, but we may still
            // be able to read the next symbol out of the previously read bits.
            // First, undo the readByte that the ensureNBits call made.
            if (self.bytes.num_unreadable != 0) {
                self.unreadByteStuffedByte();
            }
            break :blk true;
        };
        break :blk false;
    } else false;

    if (!goto_slow_path) {
        // This fast path tries to decode the Huffman code with a single lookup from the table.
        const lookupValue = huff_table.lut[(self.bits.a >> @intCast(self.bits.n - HuffTable.lut_size)) & 0xff];
        if (lookupValue != 0) {
            // The lower byte encodes how many bits to consume (minus one).
            const bitCount = @as(i32, @intCast(lookupValue & 0xff)) - 1;
            // Reduce the available bits and shift the bit mask to align with the next code boundary.
            self.bits.n -= @intCast(bitCount);
            self.bits.m >>= @intCast(bitCount);
            // The upper byte holds the symbol; return it as our decoded value.
            return @as(u8, @intCast(lookupValue >> 8));
        }
    }

    // Slow path: Bit-by-bit decoding.
    var code: i32 = 0;
    for (0..HuffTable.max_code_length) |i| {
        // Ensure at least one bit is loaded.
        if (self.bits.n == 0) {
            try self.ensureNBits(1);
        }

        // Check the top bit. If set, increment 'code' by 1.
        if ((self.bits.a & self.bits.m) != 0) {
            code |= 1;
        }

        // Move to the next bit position.
        self.bits.n -= 1;
        self.bits.m >>= 1;

        // If 'code' is within range for this code length, return the symbol.
        if (code <= huff_table.max_codes[i]) {
            return huff_table.vals[@as(usize, @intCast(huff_table.vals_indices[i] + code - huff_table.min_codes[i]))];
        }

        // Shift 'code' to match the next code length.
        code <<= 1;
    } else return error.BadHuffmanCode;
}

// ensureNBits reads bytes from the byte buffer to ensure that self.bits.n is at
// least n. For best performance (avoiding function calls inside hot loops),
// the caller is the one responsible for first checking that self.bits.n < n.
fn ensureNBits(self: *Decoder, n: i32) !void {
    while (true) {
        const c = try self.readByteStuffedByte();
        self.bits.a = (self.bits.a << 8) | @as(u32, c);
        self.bits.n += 8;

        if (self.bits.m == 0) {
            self.bits.m = 1 << 7;
        } else {
            self.bits.m <<= 8;
        }

        if (self.bits.n >= n) {
            break;
        }
    }
}

// decodeBit reads a single bit from the bit-stream.
fn decodeBit(self: *Decoder) !bool {
    if (self.bits.n == 0) {
        try self.ensureNBits(1);
    }
    // Determine if the current bit is set by masking the shift register.
    // This keeps the decoding logic straightforward by revealing only a single bit at a time.
    const ret = self.bits.a & self.bits.m != 0;

    // Consume one bit, ensuring future reads focus on the next available bit.
    self.bits.n -= 1;
    self.bits.m >>= 1;
    return ret;
}

// decodeBits reads n bits from the bit-stream.
fn decodeBits(self: *Decoder, n: i32) !u32 {
    if (self.bits.n < n) {
        try self.ensureNBits(n);
    }
    // Shifts the accumulated bits to target only the earliest unread portion
    var ret: u32 = self.bits.a >> @as(u5, @intCast(self.bits.n - n));
    // Masks out just the relevant bits for the final extracted value
    ret &= (@as(u32, 1) << @as(u5, @intCast(n))) - 1;
    // Reduces the available bit count
    self.bits.n -= n;
    // Shifts the bit mask so the next read aligns correctly
    self.bits.m >>= @as(u5, @intCast(n));
    return ret;
}

// processDHT processes a Define Huffman Table marker, and initializes a huffman
// struct from its contents. Specified in section B.2.4.2.
fn processDht(self: *Decoder, n: i32) !void {
    // make a mutable copy of n
    var local_n = n;

    while (local_n > 0) {
        if (local_n < HuffTable.max_code_length + 1) {
            return error.DhtWrongLength;
        }
        try self.readFull(self.tmp[0 .. HuffTable.max_code_length + 1]);
        const tc = self.tmp[0] >> 4;
        if (tc > max_tc) {
            return error.BadTcValue;
        }
        const th = self.tmp[0] & 0x0f;
        // The baseline th <= 1 restriction is specified in table B.5.
        if (th > max_th or (self.baseline and th > 1)) {
            return error.BadThValue;
        }
        const huff_table = &self.huff[tc][th];

        // Read num_codes and h.vals (and derive h.num_codes).
        // num_codes[i] is the number of codes with code length i.
        // h.num_codes is the total number of codes.
        huff_table.num_codes = 0;
        var num_codes = try self.al.alloc(i32, HuffTable.max_code_length);
        defer self.al.free(num_codes);

        for (0..num_codes.len) |i| {
            num_codes[i] = self.tmp[i + 1];
            huff_table.num_codes += num_codes[i];
        }
        if (huff_table.num_codes == 0) {
            return error.HuffZeroLength;
        }
        if (huff_table.num_codes > HuffTable.max_num_codes) {
            return error.HuffTooLong;
        }
        local_n -= huff_table.num_codes + HuffTable.max_code_length + 1;
        if (local_n < 0) {
            return error.DhtWrongLength;
        }
        const huff_codes_len: usize = @intCast(huff_table.num_codes);
        try self.readFull(huff_table.vals[0..huff_codes_len]);

        // Derive the look-up table.
        huff_table.clearLut();
        var code: u32 = 0;
        var val_index: usize = 0;
        for (0..HuffTable.lut_size) |i| {
            code <<= 1;
            var j: usize = 0;
            while (j < num_codes[i]) : (j += 1) {
                // The codeLength is 1+i, so shift code by 8-(1+i) to
                // calculate the high bits for every 8-bit sequence
                // whose codeLength's high bits matches code.
                // The high 8 bits of lut_value are the encoded value.
                // The low 8 bits are 1 plus the codeLength.
                const base: u32 = code << @intCast(7 - i);
                const lut_value: u16 = @as(u16, huff_table.vals[val_index]) << @intCast(8) | @as(u16, @intCast(2 + i));
                for (0..@as(u16, 1) << @intCast(7 - i)) |k| {
                    huff_table.lut[base | k] = lut_value;
                }
                code += 1;
                val_index += 1;
            }
        }

        // Derive min_codes, max_codes, and vals_indices.
        var code_base: i32 = 0;
        var index: i32 = 0;
        for (num_codes, 0..) |num_code, i| {
            if (num_code == 0) {
                huff_table.min_codes[i] = -1;
                huff_table.max_codes[i] = -1;
                huff_table.vals_indices[i] = -1;
            } else {
                huff_table.min_codes[i] = code_base;
                huff_table.max_codes[i] = code_base + num_code - 1;
                huff_table.vals_indices[i] = index;
                code_base += num_code;
                index += num_code;
            }
            code_base <<= 1;
        }
    }
}

// receiveExtend is the composition of RECEIVE and EXTEND, specified in section
// F.2.2.1.
fn receiveExtend(self: *Decoder, bit_count: u8) !i32 {
    if (self.bits.n < @as(i32, bit_count)) {
        try self.ensureNBits(@as(i32, bit_count));
    }

    // Adjust bit count and shift
    self.bits.n -= @as(i32, bit_count);
    self.bits.m >>= @intCast(bit_count);

    // Perform RECEIVE step
    const threshold = @as(i32, 1) << @intCast(bit_count);
    var value: i32 = @intCast((self.bits.a >> @intCast(self.bits.n)) & @as(u32, @intCast(threshold - 1)));

    // Perform EXTEND step
    if (value < (threshold >> 1)) {
        value += ((@as(i32, -1) << @intCast(bit_count)) + 1);
    }

    return value;
}

//===================================//
// # End Huffman Processing
//===================================//
// ********************************* //
// ********************************* //
//===================================//
// # Scan Processing
//===================================//
// processSos decodes the pixel data. The scan portion of decoding is the most complex part. It's responsible for
// reading the image data, decoding the Huffman-encoded data, and performing the
// inverse DCT to reconstruct the image data.
// n is the number of bytes in the scan segment.
fn processSos(self: *Decoder, n: i32) !void {
    if (self.num_components == 0) {
        return error.MissingSosMarker;
    }

    if (n < 6 or 4 + 2 * self.num_components < n or @mod(n, 2) != 0) {
        std.log.err("n: {d}, num_comp: {d}", .{ n, self.num_components });
        return error.SosWrongLength;
    }

    try self.readFull(self.tmp[0..@intCast(n)]);

    // top of buffer is the number of components in the scan
    const n_comp = self.tmp[0];

    if (n != 4 + 2 * n_comp) {
        return error.SosWrongLength;
    }

    const ScanComponent = struct {
        id: u8 = 0,
        td: u8 = 0, // DC table selector.
        ta: u8 = 0, // AC table selector.
    };
    var scan = [_]ScanComponent{.{}} ** max_components;
    // defer self.al.free(scan);

    // Accumulating horizontal and vertical sampling factors
    var total_hv_sampling_factors: i32 = 0;
    for (0..n_comp) |i| {
        const component_selector = self.tmp[1 + 2 * i];
        var component_index: ?usize = null;
        for (self.component[0..self.num_components], 0..) |comp, j| {
            if (component_selector == comp.id) {
                component_index = j;
                break;
            }
        }
        if (component_index == null) {
            return error.UnknownComponentSelector;
        }
        scan[i].id = @intCast(component_index.?);
        // Section B.2.3 states that "the value of Cs_j shall be different from
        // the values of Cs_1 through Cs_(j-1)". Since we have previously
        // verified that a frame's component identifiers (C_i values in section
        // B.2.2) are unique, it suffices to check that the implicit indexes
        // into self.comp are unique.
        for (0..i) |j| {
            if (scan[i].id == scan[j].id) {
                return error.RepeatedComponentIdentifier;
            }
        }
        total_hv_sampling_factors += self.component[component_index.?].h * self.component[component_index.?].v;
        // The baseline t <= 1 restriction is specified in table B.3.
        scan[i].td = self.tmp[2 + 2 * i] >> 4;
        var table_elector = scan[i].td;
        if (table_elector > max_th or (self.baseline and table_elector > 1)) {
            return error.BadTdValue;
        }
        scan[i].ta = self.tmp[2 + 2 * i] & 0x0f;
        table_elector = scan[i].ta;
        if (table_elector > max_th or (self.baseline and table_elector > 1)) {
            return error.BadTaValue;
        }
    }

    // Section B.2.3 states that if there is more than one component then the
    // total H*V values in a scan must be <= 10.
    if (self.num_components > 1 and total_hv_sampling_factors > 10) {
        return error.SamplingFactorsTooLarge;
    }

    // zig_start and zig_end are the spectral selection bounds.
    // ah and al are the successive approximation high and low values.
    // The spec calls these values Ss, Se, Ah and Al.
    //
    // For progressive JPEGs, these are the two more-or-less independent
    // aspects of progression. Spectral selection progression is when not
    // all of a block's 64 DCT coefficients are transmitted in one pass.
    // For example, three passes could transmit coefficient 0 (the DC
    // component), coefficients 1-5, and coefficients 6-63, in zig-zag
    // order. Successive approximation is when not all of the bits of a
    // band of coefficients are transmitted in one pass. For example,
    // three passes could transmit the 6 most significant bits, followed
    // by the second-least significant bit, followed by the least
    // significant bit.
    //
    // For sequential JPEGs, these parameters are hard-coded to 0/63/0/0, as
    // per table B.3.
    var zig_start: i32 = 0;
    var zig_end: i32 = idct.block_size - 1;
    var ah: u32 = 0;
    var al: u32 = 0;
    if (self.progressive) {
        zig_start = self.tmp[1 + 2 * n_comp];
        zig_end = self.tmp[2 + 2 * n_comp];
        ah = self.tmp[3 + 2 * n_comp] >> 4;
        al = self.tmp[3 + 2 * n_comp] & 0x0f;
        if ((zig_start == 0 and zig_end != 0) or zig_start > zig_end or idct.block_size <= zig_end) {
            return error.BadSpectralSelection;
        }
        if (zig_start != 0 and n_comp != 1) {
            return error.ProgressiveACCoefficientsForMoreThanOneComponent;
        }
        if (ah != 0 and ah != al + 1) {
            return error.BadSuccessiveApproximation;
        }
    }

    // mxx and myy are the number of MCUs (Minimum Coded Units) in the image.
    const h0 = self.component[0].h;
    const v0 = self.component[0].v;
    const w: i32 = @intCast(self.width);
    const h: i32 = @intCast(self.height);
    const mxx = @divTrunc(w + 8 * h0 - 1, 8 * h0);
    const myy = @divTrunc(h + 8 * v0 - 1, 8 * v0);
    if (self.ycbcr_img == null) {
        try self.makeImg(mxx, myy);
    }

    if (self.progressive) {
        var i: usize = 0;
        while (i < self.num_components) : (i += 1) {
            const component_index = scan[i].id;
            if (self.progressive_coefficients[component_index] == null) {
                const prog_block_size: usize = @intCast(mxx * myy * self.component[component_index].h * self.component[component_index].v);
                self.progressive_coefficients[component_index] = try self.al.alloc(
                    idct.Block,
                    prog_block_size,
                );
                for (0..prog_block_size) |j| {
                    self.progressive_coefficients[component_index].?[j] = idct.emptyBlock();
                }
            }
        }
    }

    self.bits = Bits{};
    var mcu: i32 = 0;
    var expected_rst = Marker.rst0;
    var bx: i32 = 0;
    var by: i32 = 0;
    var block_count: i32 = 0;
    var dc: [max_components]i32 = [_]i32{0} ** max_components;
    var b: idct.Block = undefined;

    for (0..@intCast(myy)) |my| {
        for (0..@intCast(mxx)) |mx| {
            for (0..n_comp) |k| {
                const c_index = scan[k].id;
                const hi = self.component[c_index].h;
                const vi = self.component[c_index].v;

                for (0..@intCast(hi * vi)) |j| {
                    // The blocks are traversed one MCU at a time. For 4:2:0 chroma
                    // subsampling, there are four Y 8x8 blocks in every 16x16 MCU.
                    //
                    // For a sequential 32x16 pixel image, the Y blocks visiting order is:
                    //  0 1 4 5
                    //  2 3 6 7
                    //
                    // For progressive images, the interleaved scans (those with nComp > 1)
                    // are traversed as above, but non-interleaved scans are traversed left
                    // to right, top to bottom:
                    //  0 1 2 3
                    //  4 5 6 7
                    // Only DC scans (zigStart == 0) can be interleaved. AC scans must have
                    // only one component.
                    //
                    // To further complicate matters, for non-interleaved scans, there is no
                    // data for any blocks that are inside the image at the MCU level but
                    // outside the image at the pixel level. For example, a 24x16 pixel 4:2:0
                    // progressive image consists of two 16x16 MCUs. The interleaved scans
                    // will process 8 Y blocks:
                    //  0 1 4 5
                    //  2 3 6 7
                    // The non-interleaved scans will process only 6 Y blocks:
                    //  0 1 2
                    //  3 4 5
                    if (n_comp != 1) {
                        bx = hi * @as(i32, @intCast(mx)) + @mod(@as(i32, @intCast(j)), hi);
                        by = vi * @as(i32, @intCast(my)) + @divTrunc(@as(i32, @intCast(j)), hi);
                    } else {
                        bx = @mod(block_count, mxx * hi);
                        by = @divTrunc(block_count, mxx * hi);
                        block_count += 1;
                        if (bx * 8 >= self.width or by * 8 >= self.height) {
                            continue;
                        }
                    }

                    // Load the previous partially decoded coefficients, if applicable.
                    if (self.progressive) {
                        const block_index: usize = @intCast(by * mxx * hi + bx);
                        b = self.progressive_coefficients[c_index].?[block_index];
                    } else {
                        b = idct.emptyBlock();
                    }

                    // Reconstruct each 8x8 block’s DC/AC coefficients.
                    // It references a standard zigzag array (unzig) to place coefficients in the correct
                    // order for the subsequent dequantization and IDCT steps. By reordering from low to
                    // high frequency, it supports more efficient skipping of zero blocks and ensures the
                    // final image is accurately reconstructed.
                    //
                    // Refine existing DC bits instead of decoding new ones.
                    if (ah != 0) {
                        try self.refine(
                            &b,
                            &self.huff[ac_table][scan[k].ta],
                            zig_start,
                            zig_end,
                            @as(i32, 1) << @intCast(al),
                        );
                    } else {
                        var zig: i32 = zig_start;

                        // Decode DC coefficient for the first slot.
                        if (zig == 0) {
                            zig += 1;
                            // Decode the DC coefficient, as specified in section F.2.2.1.
                            const value = try self.decodeHuffman(&self.huff[dc_table][scan[k].td]);
                            if (value > 16) {
                                return error.ExcessiveDCComponent;
                            }
                            const dc_delta = try self.receiveExtend(value);
                            dc[c_index] += dc_delta;
                            b[0] = dc[c_index] << @intCast(al);
                        }

                        // Use remaining EOB run if available, else decode AC.
                        if (zig <= zig_end and self.eob_run > 0) {
                            self.eob_run -= 1;
                        } else {
                            // Decode the AC coefficients, as specified in section F.2.2.2.
                            const huff = &self.huff[ac_table][scan[k].ta];

                            // Decode AC coefficients until EOB or end of range.
                            while (zig <= zig_end) : (zig += 1) {
                                const value = try self.decodeHuffman(huff);
                                const val0 = value >> 4;
                                const val1 = value & 0x0f;

                                if (val1 != 0) {
                                    zig += @intCast(val0);
                                    if (zig > zig_end) {
                                        break;
                                    }
                                    const ac = try self.receiveExtend(val1);
                                    b[unzig[@intCast(zig)]] = ac << @intCast(al);
                                } else {
                                    if (val0 != 0x0f) {
                                        self.eob_run = @as(u16, 1) << @intCast(val0);
                                        if (val0 != 0) {
                                            const bits = try self.decodeBits(@intCast(val0));
                                            self.eob_run |= @intCast(bits);
                                        }
                                        self.eob_run -= 1;
                                        break;
                                    }
                                    zig += 0x0f;
                                }
                            }
                        }
                    }

                    if (self.progressive) {
                        const block_index: usize = @intCast(by * mxx * hi + bx);
                        self.progressive_coefficients[c_index].?[block_index] = b;
                        // At this point, we could call reconstructBlock to dequantize and perform the
                        // inverse DCT, to save early stages of a progressive image to the *image.YCbCr
                        // buffers (the whole point of progressive encoding), but in Go, the jpeg.Decode
                        // function does not return until the entire image is decoded, so we "continue"
                        // here to avoid wasted computation. Instead, reconstructBlock is called on each
                        // accumulated block by the reconstructProgressiveImage method after all of the
                        // SOS markers are processed.
                        continue;
                    }
                    try self.reconstructBlock(&b, bx, by, @intCast(c_index));
                }
            }

            mcu += 1;

            if (self.restart_interval > 0 and @mod(mcu, self.restart_interval) == 0 and mcu < mxx * myy) {
                // For well-formed input, the RST[0-7] restart marker follows
                // immediately. For corrupt input, call findRST to try to
                // resynchronize.
                try self.readFull(self.tmp[0..2]);
                if (self.tmp[0] != 0xff or self.tmp[1] != @intFromEnum(expected_rst)) {
                    try self.findRst(@intFromEnum(expected_rst));
                }
                expected_rst = @enumFromInt(@intFromEnum(expected_rst) + 1);
                const max_rst: Marker = @enumFromInt(@intFromEnum(Marker.rst7) + 1);
                // wrap around
                if (expected_rst == max_rst) {
                    expected_rst = Marker.rst0;
                }
                // Reset the Huffman decoder.
                self.bits = Bits{};
                // Reset the DC components, as per section F.2.1.3.1.
                dc = [_]i32{0} ** max_components;
                // Reset the progressive decoder state, as per section G.1.2.2.
                self.eob_run = 0;
            }
        }
    }
}

// refine decodes a successive approximation refinement block, as specified in
// section G.1.2.
fn refine(self: *Decoder, b: *idct.Block, h: *HuffTable, zig_start: i32, zig_end: i32, delta: i32) !void {
    // Refining a DC component is trivial.
    if (zig_start == 0) {
        if (zig_end != 0) unreachable;

        const bit = try self.decodeBit();
        if (bit) {
            b[0] |= delta;
        }
        return;
    }

    // Refining AC components is more complicated; see sections G.1.2.2 and G.1.2.3.
    var zig: i32 = zig_start;

    if (self.eob_run == 0) {
        loop: while (zig <= zig_end) : (zig += 1) {
            var z: i32 = 0;
            const value = try self.decodeHuffman(h);
            const val0 = value >> 4;
            const val1 = value & 0x0F;

            switch (val1) {
                0 => {
                    if (val0 != 0x0F) {
                        self.eob_run = @as(u16, 1) << @intCast(val0);
                        if (val0 != 0) {
                            const bits = try self.decodeBits(@intCast(val0));
                            self.eob_run |= @as(u16, @intCast(bits));
                        }
                        break :loop;
                    }
                },
                1 => {
                    z = delta;
                    const bit = try self.decodeBit();
                    if (!bit) {
                        z = -z;
                    }
                },
                else => {
                    return error.UnexpectedHuffmanCode;
                },
            }

            zig = try self.refineNonZeroes(b, zig, zig_end, @intCast(val0), delta);
            if (zig > zig_end) {
                return error.TooManyCoefficients;
            }
            if (z != 0) {
                b[unzig[@intCast(zig)]] = z;
            }
        }
    }

    if (self.eob_run > 0) {
        self.eob_run -= 1;
        _ = try self.refineNonZeroes(b, zig, zig_end, -1, delta);
    }
}

// refineNonZeroes refines non-zero entries of b in zig-zag order. If nz >= 0,
// the first nz zero entries are skipped over.
fn refineNonZeroes(self: *Decoder, b: *idct.Block, zig: i32, zig_end: i32, nz: i32, delta: i32) !i32 {
    // make mutable copies
    var local_nz = nz;
    var local_zig = zig;

    while (local_zig <= zig_end) : (local_zig += 1) {
        const index = unzig[@intCast(local_zig)];
        if (b[index] == 0) {
            if (local_nz == 0) {
                break;
            }
            local_nz -= 1;
            continue;
        }

        const bit = try self.decodeBit();
        if (!bit) {
            continue;
        }

        if (b[index] >= 0) {
            b[index] += delta;
        } else {
            b[index] -= delta;
        }
    }
    return local_zig;
}

// reconstructBlock dequantizes, performs the inverse DCT and stores the block
// to the image.
pub fn reconstructBlock(
    self: *Decoder,
    b: *idct.Block,
    block_x: i32,
    block_y: i32,
    component_index: usize,
) !void {
    const bx: usize = @intCast(block_x);
    const by: usize = @intCast(block_y);

    // Step 1: Dequantize the block.
    const qt = &self.quant[self.component[component_index].tq];
    for (0..idct.block_size) |zig| {
        b[unzig[zig]] *= qt[zig];
    }

    // Step 2: Perform the Inverse Discrete Cosine Transform (IDCT).
    idct.transform(b);

    // Step 3: Map the dequantized block to the destination buffer.
    var dest_pixels: []u8 = undefined;
    var stride: usize = 0;
    if (self.num_components == 1) {
        // Single-component (Grayscale)
        if (self.gray_img) |gray_img| {
            dest_pixels = gray_img.pixels[8 * (by * gray_img.stride + bx) ..];
            stride = gray_img.stride;
        } else {
            std.debug.panic("Expected Gray image for single-component JPEG", .{});
        }
    } else {
        // Multi-component (YCbCr or additional black channel)
        if (self.ycbcr_img) |ycbcr_img| {
            switch (component_index) {
                0 => {
                    dest_pixels = ycbcr_img.y[8 * (by * ycbcr_img.y_stride + bx) ..];
                    stride = ycbcr_img.y_stride;
                },
                1 => {
                    dest_pixels = ycbcr_img.cb[8 * (by * ycbcr_img.c_stride + bx) ..];
                    stride = ycbcr_img.c_stride;
                },
                2 => {
                    dest_pixels = ycbcr_img.cr[8 * (by * ycbcr_img.c_stride + bx) ..];
                    stride = ycbcr_img.c_stride;
                },
                3 => {
                    dest_pixels = self.black_pixels.?[8 * (by * self.black_stride + bx) ..];
                    stride = self.black_stride;
                },
                else => return error.UnsupportedComponent,
            }
        } else {
            std.debug.panic("Expected YCbCr image for multi-component JPEG", .{});
        }
    }

    // Step 4: Level shift by +128, clip to [0, 255], and write to destination pixels.
    for (0..8) |y| {
        // Row offset in the block.
        const y8 = y * 8;
        // Row offset in the image buffer.
        const y_stride = y * stride;

        for (0..8) |x| {
            // Get coefficient from the block.
            var coefficient: i32 = b[y8 + x];

            // Level shift and clipping.
            if (coefficient < -128) {
                coefficient = 0;
            } else if (coefficient > 127) {
                coefficient = 255;
            } else {
                coefficient += 128;
            }

            // Write clipped value to the buffer.
            dest_pixels[y_stride + x] = @as(u8, @intCast(coefficient));
        }
    }
}

pub fn reconstructProgressiveImage(self: *Decoder) !void {
    // The h0, mxx, by and bx variables have the same meaning as in the
    // processSos method.
    const h0 = self.component[0].h;
    const mxx = @divTrunc(@as(i32, @intCast(self.width)) + 8 * h0 - 1, 8 * h0);

    var i: usize = 0;
    while (i < self.num_components) : (i += 1) {
        if (self.progressive_coefficients[i] == null) continue;
        const v: usize = @intCast(8 * @divTrunc(self.component[0].v, self.component[i].v));
        const h: usize = @intCast(8 * @divTrunc(self.component[0].h, self.component[i].h));
        const stride: usize = @intCast(mxx * self.component[i].h);
        var by: usize = 0;
        while (by * v < self.height) : (by += 1) {
            var bx: usize = 0;
            while (bx * h < self.width) : (bx += 1) {
                try self.reconstructBlock(
                    &self.progressive_coefficients[i].?[by * stride + bx],
                    @intCast(bx),
                    @intCast(by),
                    i,
                );
            }
        }
    }
}
// findRST advances past the next RST restart marker that matches expected_rst.
// Other than I/O errors, it is also an error if we encounter an {0xFF, M}
// two-byte marker sequence where M is not 0x00, 0xFF or the expected_rst.
//
// This is similar to libjpeg's jdmarker.c's next_marker function.
// https://github.com/libjpeg-turbo/libjpeg-turbo/blob/2dfe6c0fe9e18671105e94f7cbf044d4a1d157e6/jdmarker.c#L892-L935
//
// Precondition: self.tmp[:2] holds the next two bytes of JPEG-encoded input
// (input in the self.readFull sense).
pub fn findRst(self: *Decoder, expected_rst: u8) !void {
    while (true) {
        // i is the index such that, at the bottom of the loop, we read 2-i
        // bytes into d.tmp[i:2], maintaining the invariant that self.tmp[:2]
        // holds the next two bytes of JPEG-encoded input. It is either 0 or 1,
        // so that each iteration advances by 1 or 2 bytes (or returns).
        var i: usize = 0;

        if (self.tmp[0] == 0xFF) {
            if (self.tmp[1] == expected_rst) {
                // Found the expected RST marker, return successfully.
                return;
            } else if (self.tmp[1] == 0xFF) {
                // Encountered another `0xFF`, skip one byte and continue.
                i = 1;
            } else if (self.tmp[1] != 0x00) {
                // libjpeg's jdmarker.c's jpeg_resync_to_restart does something
                // fancy here, treating RST markers within two (modulo 8) of
                // expected_rst differently from RST markers that are 'more
                // distant'. Until we see evidence that recovering from such
                // cases is frequent enough to be worth the complexity, we take
                // a simpler approach for now. Any marker that's not 0x00, 0xff
                // or expected_rst is an error.
                return error.BadRSTMarker;
            }
        } else if (self.tmp[1] == 0xFF) {
            // Shift the second byte to the first position and read a new second byte.
            self.tmp[0] = 0xFF;
            i = 1;
        }

        // Read the next byte(s) into `self.tmp[i..2]`, ensuring the invariant holds.
        try self.readFull(self.tmp[i..2]);
    }
}

// makeImg allocates and initializes the destination image.
fn makeImg(self: *Decoder, mxx: i32, myy: i32) !void {
    if (self.num_components == 1) {
        // Free any previous gray image allocation from progressive scans
        if (self.previous_gray_all_pixels) |pixels| {
            self.al.free(pixels);
            self.previous_gray_all_pixels = null;
        }

        // Allocate a grayscale image if there's only one component.
        const gray_image: image.GrayImage = try image.GrayImage.init(self.al, image.Rectangle.init(
            0,
            0,
            8 * mxx,
            8 * myy,
        ));
        self.gray_img = try gray_image.subImage(
            image.Rectangle.init(
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
            ),
        ) orelse return error.CreateImageFailed;

        if (self.progressive) {
            self.previous_gray_all_pixels = self.gray_img.?.pixels;
        }
        return;
    }

    // Calculate the subsampling ratio.
    // The subsampling ratio is the ratio between the dimensions of the Y component
    // and the dimensions of the Cb and Cr components.
    const h0 = self.component[0].h;
    const v0 = self.component[0].v;
    const h_ratio = @divExact(h0, self.component[1].h);
    const v_ratio = @divExact(v0, self.component[1].v);
    const subsample_ratio: image.YCbCrSubsample = switch (h_ratio << 4 | v_ratio) {
        0x11 => .Ratio444, // No subsampling.
        0x12 => .Ratio440, // Vertical subsampling.
        0x21 => .Ratio422, // Horizontal subsampling.
        0x22 => .Ratio420, // Both horizontal and vertical subsampling.
        0x41 => .Ratio411, // More horizontal subsampling.
        0x42 => .Ratio410, // More vertical subsampling.
        else => unreachable,
    };
    // Allocate a YCbCr image with the calculated subsampling ratio.
    var img: image.YCbCrImage = try image.YCbCrImage.init(self.al, image.Rectangle.init(
        0,
        0,
        8 * h0 * mxx,
        8 * v0 * myy,
    ), subsample_ratio);
    defer self.al.free(img.pixels);

    // Create a sub-image with the exact dimensions of the JPEG.
    const sub_img = try img.subImage(
        self.al,
        image.Rectangle.init(
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        ),
    ) orelse return error.CreateImageFailed;

    self.ycbcr_img = sub_img;

    if (self.num_components == 4) {
        // Allocate space for the black channel if there are four components (CMYK).
        const h3 = self.component[3].h;
        const v3 = self.component[3].v;
        self.black_pixels = try self.al.alloc(u8, @intCast(8 * h3 * mxx * 8 * v3 * myy));
        self.black_stride = @intCast(8 * h3 * mxx);
    }
}
//===================================//
// # End Scan Processing
//===================================//

//===================================//
// # Tests
//===================================//
const testing = std.testing;

fn decodeFile(path: []const u8) !image.Image {
    const jpeg_file = try std.fs.cwd().openFile(path, .{});
    defer jpeg_file.close();

    var io_buf: [4096]u8 = undefined;
    var file_reader = jpeg_file.reader(&io_buf);
    const reader: *std.Io.Reader = &file_reader.interface;
    return try decode(std.testing.allocator, reader);
}

fn check(bounds: image.Rectangle, pix0: []u8, pix1: []u8, stride0: usize, stride1: usize) !void {
    if (stride0 <= 0 or @mod(stride0, 8) != 0) {
        return error.InvalidStride;
    }
    if (stride1 <= 0 or @mod(stride1, 8) != 0) {
        return error.InvalidStride;
    }
    // Compare the two pix data, one 8x8 block at a time.
    var y: usize = 0;
    while (y < pix0.len / stride0 and y < pix1.len / stride1) : (y += 8) {
        var x: usize = 0;
        while (x < stride0 and x < stride1) : (x += 8) {
            if (x >= bounds.max.x or y >= bounds.max.y) {
                // We don't care if the two pix data differ if the 8x8 block is
                // entirely outside of the image's bounds. For example, this can
                // occur with a 4:2:0 chroma subsampling and a 1x1 image. Baseline
                // decoding works on the one 16x16 MCU as a whole; progressive
                // decoding's first pass works on that 16x16 MCU as a whole but
                // refinement passes only process one 8x8 block within the MCU.
                continue;
            }

            for (0..8) |j| {
                for (0..8) |i| {
                    const index0 = (y + j) * stride0 + (x + i);
                    const index1 = (y + j) * stride1 + (x + i);
                    if (pix0[index0] != pix1[index1]) {
                        return error.InvalidPixData;
                    }
                }
            }
        }
    }
}

fn readerFromSlice(data: []const u8) std.Io.Reader {
    const reader_val = std.Io.Reader.fixed(data);
    return reader_val;
}

test "decode + progressive" {
    const al = std.testing.allocator;
    const test_cases = [_][]const u8{
        "src/testdata/video-001",
        "src/testdata/video-001.q50.410",
        "src/testdata/video-001.q50.411",
        "src/testdata/video-001.q50.420",
        "src/testdata/video-001.q50.422",
        "src/testdata/video-001.q50.440",
        "src/testdata/video-001.q50.444",
        "src/testdata/video-005.gray.q50",
        "src/testdata/video-005.gray.q50.2x2",
        "src/testdata/video-001.separate.dc.progression",
    };
    var i: usize = 0;
    while (i < test_cases.len) : (i += 1) {
        const path = test_cases[i];

        var file_name = try std.fmt.allocPrint(al, "{s}{s}", .{ path, ".jpeg" });
        const img1 = try decodeFile(file_name);
        al.free(file_name);
        defer img1.free(al);
        file_name = try std.fmt.allocPrint(al, "{s}{s}", .{ path, ".progressive.jpeg" });
        const img2 = try decodeFile(file_name);
        defer img2.free(al);
        defer al.free(file_name);

        try testing.expectEqual(img1.bounds(), img2.bounds());
        try testing.expectEqual(img1.bounds(), image.Rectangle{
            .min = image.Point{ .x = 0, .y = 0 },
            .max = image.Point{ .x = 150, .y = 103 },
        });

        switch (img1) {
            .Gray => |m0| {
                const m1 = switch (img2) {
                    .Gray => |m| m,
                    else => return error.InvalidImageType,
                };
                try check(
                    m0.bounds(),
                    m0.pixels,
                    m1.pixels,
                    m0.stride,
                    m1.stride,
                );
            },
            .YCbCr => |m0| {
                const m1 = switch (img2) {
                    .YCbCr => |m| m,
                    else => return error.InvalidImageType,
                };
                try check(
                    m0.bounds(),
                    m0.y,
                    m1.y,
                    m0.y_stride,
                    m1.y_stride,
                );
                try check(
                    m0.bounds(),
                    m0.cb,
                    m1.cb,
                    m0.c_stride,
                    m1.c_stride,
                );
                try check(
                    m0.bounds(),
                    m0.cr,
                    m1.cr,
                    m0.c_stride,
                    m1.c_stride,
                );
            },
            else => return error.InvalidImageType,
        }
    }
}

test "decode assorted" {
    const al = std.testing.allocator;
    const test_cases = [_][]const u8{
        "src/testdata/video-001.cmyk",
        "src/testdata/video-001.221212",
        "src/testdata/video-005.gray",
        "src/testdata/video-001.rgb",
        "src/testdata/video-001.separate.dc.progression",
    };
    var i: usize = 0;
    while (i < test_cases.len) : (i += 1) {
        const path = test_cases[i];

        const file_name = try std.fmt.allocPrint(al, "{s}{s}", .{ path, ".jpeg" });
        const img1 = try decodeFile(file_name);
        al.free(file_name);
        img1.free(al);
    }
}

test "truncated SOS doesn't panic" {
    const al = std.testing.allocator;
    const path = "src/testdata/video-005.gray.q50.jpeg";

    const b = try std.fs.cwd().readFileAlloc(al, path, 100000);
    defer al.free(b);

    const sos_marker = [_]u8{ 0xff, 0xda };
    var i = std.mem.indexOf(u8, b, &sos_marker) orelse return error.SOSMarkerNotFound;
    i += 2;
    var j = i + 10;
    if (j > b.len) {
        j = b.len;
    }
    while (i < j) : (i += 1) {
        var reader_val = std.Io.Reader.fixed(b[0..i]);
        const reader: *std.Io.Reader = &reader_val;

        const result = decode(al, reader);
        try testing.expectError(error.UnexpectedEof, result);
    }
}

test "large image with short data" {
    const al = std.testing.allocator;

    // This input is an invalid JPEG image, based on the fuzzer-generated image
    // in issue 10413. It is only 504 bytes, and shouldn't take long for Decode
    // to return an error. The Start Of Frame marker gives the image dimensions
    // as 8192 wide and 8192 high, so even if an unreadByteStuffedByte bug
    // doesn't technically lead to an infinite loop, such a bug can still cause
    // an unreasonably long loop for such a short input.
    const input: []const u8 = &[_]u8{
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
        0x00, 0x10, 0x0b, 0x0c, 0x0e, 0x0c, 0x0a, 0x10, 0x0e, 0x89, 0x0e, 0x12,
        0x11, 0x10, 0x13, 0x18, 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46,
        0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xff, 0xdb, 0x00, 0x43, 0x00, 0x10, 0x0b, 0x0c, 0x0e, 0x0c, 0x0a, 0x10,
        0x0e, 0x0d, 0x0e, 0x12, 0x11, 0x10, 0x13, 0x18, 0x28, 0x1a, 0x18, 0x16,
        0x16, 0x18, 0x31, 0x23, 0x25, 0x1d, 0x28, 0x3a, 0x33, 0x3d, 0x3c, 0x39,
        0x33, 0x38, 0x37, 0x40, 0x48, 0x5c, 0x4e, 0x40, 0x44, 0x57, 0x45, 0x37,
        0x38, 0x50, 0x6d, 0x51, 0x57, 0x5f, 0x62, 0x67, 0x68, 0x67, 0x3e, 0x4d,
        0x71, 0x79, 0x70, 0x64, 0x78, 0x5c, 0x65, 0x67, 0x63, 0xff, 0xc0, 0x00,
        0x0b, 0x08, 0x20, 0x00, 0x20, 0x00, 0x01, 0x01, 0x11, 0x00, 0xff, 0xc4,
        0x00, 0x1f, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x10,
        0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04,
        0x00, 0x00, 0x01, 0x7d, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x01, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
        0x81, 0x91, 0xa1, 0x08, 0x23, 0xd8, 0xff, 0xdd, 0x42, 0xb1, 0xc1, 0x15,
        0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a,
        0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x00, 0x63, 0x64, 0x65,
        0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94,
        0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
        0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10,
        0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0xff, 0xdb, 0x00, 0x43, 0x00, 0x10, 0x0b, 0x0c, 0x0e, 0x0c,
        0x0a, 0x10, 0x0e, 0x0d, 0x0e, 0x12, 0x11, 0x10, 0x13, 0x18, 0x28, 0x1a,
        0x18, 0x16, 0x16, 0x18, 0x31, 0x23, 0x25, 0x1d, 0xc8, 0xc9, 0xca, 0xd2,
        0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4,
        0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6,
        0xf7, 0xf8, 0xf9, 0xfa, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00,
        0x3f, 0x00, 0xb9, 0xeb, 0x50, 0xb0, 0xdb, 0xc8, 0xa8, 0xe4, 0x63, 0x80,
        0xdd, 0x31, 0xd6, 0x9d, 0xbb, 0xf2, 0xc5, 0x42, 0x1f, 0x6c, 0x6f, 0xf4,
        0x34, 0xdd, 0x3c, 0xfc, 0xac, 0xe7, 0x3d, 0x80, 0xa9, 0xcc, 0x87, 0x34,
        0xb3, 0x37, 0xfa, 0x2b, 0x9f, 0x6a, 0xad, 0x63, 0x20, 0x36, 0x9f, 0x78,
        0x64, 0x75, 0xe6, 0xab, 0x7d, 0xb2, 0xde, 0x29, 0x70, 0xd3, 0x20, 0x27,
        0xde, 0xaf, 0xa4, 0xf0, 0xca, 0x9f, 0x24, 0xa8, 0xdf, 0x46, 0xa8, 0x24,
        0x84, 0x96, 0xe3, 0x77, 0xf9, 0x2e, 0xe0, 0x0a, 0x62, 0x7f, 0xdf, 0xd9,
    };

    // Wrap the input in a fixed reader to simulate a reader.
    var reader_val = std.Io.Reader.fixed(input);
    const reader: *std.Io.Reader = &reader_val;

    // Attempt to decode the JPEG image.
    const decode_result = decode(al, reader);

    try testing.expectError(error.UnexpectedEof, decode_result);
}

test "padded rst marker" {
    // This test image comes from golang.org/issue/28717
    const base64EncodedImage =
        \\/9j/4AAhQVZJMQABAQEAeAB4AAAAAAAAAAAAAAAAAAAAAAAAAP/bAEMABAIDAwMCBAMDAwQEBAQGCgYG
        \\BQUGDAgJBwoODA8PDgwODxASFxMQERURDQ4UGhQVFxgZGhkPExweHBkeFxkZGP/bAEMBBAQEBgUGCwYG
        \\CxgQDhAYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGP/EAaIA
        \\AAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKCxAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1Fh
        \\ByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNk
        \\ZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT
        \\1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6AQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgsRAAIB
        \\AgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBka
        \\JicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZ
        \\mqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/dAAQA
        \\Cv/gAAQAAP/AABEIALABQAMBIQACEQEDEQH/2gAMAwEAAhEDEQA/APnCFTk5BPPGKliAB718W7H2j3Ip
        \\VUuwJxzTfKXacde9VBhYRUBAyO3pTmUAbSMU5WGmybywzHGAMdelPVFC+n1qXZCuyaJADxjj2qzbBMAP
        \\xz1rKaVib6ltLcFvlIx2pLy0dwuAMMBnH1rFON9RNsszAZPFEYHldPzrOy3KewmBk9qUABugxjtTVmiW
        \\xWRcjp+VJtHXgVL3K6AgBDdM9eRTNzAZViOe1VyxaJavuf/Q8aW4mUcSGpo764AyHz+FfnnJBvVH1UsN
        \\CS1Q/wDte4Trip49ecA7g3FSqMW9zlqZandxJ4/EKADcSPqKni8QQMT865qOSUNjiqZdNbFiHWYXz84N
        \\WE1KNsfMKj2zirHHPDSj0JFvo2H36d9pUjg1sqykYOm0KbgY60omXPXmr9pFkco3zBnrQzjGcnrRzp9S
        \\bEbuOvao3fisZSXUpIYWGKGcbetTCSswsxnmACkYrtNSpJ2YNM//0fnK1BD7sDg9KmUHeOe/Svid3qfb
        \\SdmQ3AHmnr1pGBC5z19a0hohNiJkensM1J0yCKmY0yZR82e+BT1BxnpmpepN9SRCR0NSpweOoPWs6isr
        \\ijuWIZGBA/lVwzMVFY8ibuhXEfr+tOz8hIqUymhRnJGTSc5wBVRRDFPXBHJpB3qdmV0EX7vXmoyfl685
        \\p2dxWR//0vFsHZ9TQv3T618Bqz7PSwwn1phPXpSWrQEUhIx0NVXc7j0rSNwViCS4dWYpJj3BpBqVzGy7
        \\ZmHSq9kpblSpxkveQ+PX7uMf6wEDtU0fi24TAkX8jTeCjJaaHDUwFN7aFq28aL/GCMGrtr4xtHGGkA+t
        \\YTy+a+E82eAa2LsXiWzI5mXPHercOsW8hwJB+dcUqVSCOKVFxdmiwl7E2MOPzp4nQ9GH51jzNbmUoOIC
        \\TI4okOaUXoybDCevNBPHX8qIO4mf/9P52i4dix5zjp/n1qZFBCmviL6an2kt9CGcYnJznJpOBwegq4vQ
        \\L9xIUytSkfu/bv70p7j6EnQgjHSpFGVqXclkkaHb1+makUHgdazm7IFuSKOasrnjis2+oDm9qnIHlgd/
        \\es7gxqjkt1NLwH4xTTEhjkhutM3D15oGhkcnBGRTDKu3A7H1rS3cLn//1PEhJ8uM557UvmDaa/P7a3Ps
        \\xpZcZ6mo5WG45pdUC2K8ko5JIzWfcTqu7HPHrW9OLbKWhSluVLNz3wKrS3I3KfcV1Rg9CrpXK8l0F7io
        \\pLnLnJHGOldMYJGMpu5XNwuxjyRTBcAAjd1HWtfZmPORy3WAWWQDOM4PWtHRru6DFlmY88ZqKsVyXaKp
        \\QjOoa7axe28G/cWqhoHjO/n1WeJwSkS9c981wUcFCopPayFj8JC8VFbs6e38VldvmHHFaMHimAoCzDB6
        \\V5U8FKz5TlrZU4/CXYtdtnXIarEepW7jAcfnXGqEoKx5tfBzh0P/1fnqEAsc/wB6pI9owAD1618Qn3Ps
        \\35EE4UzHrx79aXaMcdaqAMWIADvj271IMeXg59KUmNLQkUDfjb1FSLxzg0pWJRLGAQAeMVIoA+uaxlaw
        \\0SoF/u1KowwwDUcwuo9wMjrUrY2ZPOKy0KY1T1NMdwG/CtBEFzMqnIPNUZ75FBJP5mtIQvYfoU21JFVs
        \\N271AurRE/e611xw73Yj/9b50GsQhOXHWnpq8JX7w4PWvjPq76H2fzHjVYCud9Q3GrRAZDUvq75kNbMz
        \\7vV0zjdjNZ82pqzMcj7tdlPDtIiVWKKct+AxwRxUbXi7VPJAIrZUdEZOsrsga8DFgelQtd98g5P6V0Qp
        \\GE6qIUut2cZ470kd2FjYc4Oce1bSpJ3Rzxq21GNcDZhSeg710ujKRbKzAg5rkxceWnqd+XtOo7bD9cl8
        \\qxLDPHasXwUvmyXU7Lgl8cegrnw2lGbZ14l3rU0bl3gMQCRgVU1y7WytUZQzMRwBXPRhzWRvVny3ZW8N
        \\6xPdXBikiZc5IOa6GG6nDsd5xnAyfaliqEacrGOHarx5pI//1/nuL754HWngEkYx1r4VWsfaMjk4mP8A
        \\OgnjPH1rRMLKwR4A2jH1FPA+TNRIa0ROvQcY4p4GF/pUskmi6+gqRACvPrWMnpca3JABjFSKCQOnFS2u
        \\o7E3XBOKcR8ucdKzUkDGSHGemKpXchVuP0rSmDMfUrl1J5rn9TvnVCc9OtelhoJtDekW0Yb6pId3zdRw
        \\RVT+0pAPvc57CvbhQVrHlTxD3P8A/9D4tbUpTH1I7cU/7ZdMnyqcdsV5vsErXPbWJbHLdXzYQDBY8c02
        \\6udQjyGVuD1FHsqfMridepZ6ED3s4IDqeD0I68VEt7J5hy3GO9aKkuhPt2BumeRjnv3pJLlgwBYE8ZqH
        \\T2GqujYLcuWYbhj0zTHm5B/vcGtVBLYzdRtEcUueoGB3FOjmBjcBhx2NNx1IhO+uwtqd93EgA5YcV32n
        \\IqwrnAz2rzMx+FI9nKldy+RmeMpfLs8DGTxTvBUKw6Csjry2WPbrXHB2wzfdnbUu8SvJF4xh1LDAJNU9
        \\UtVmDs3IiGB6CuenNx1R0yjfRGd4aRTqJdFG1ARXRgANg4/yK0xbvJehnhlaL9T/AP/R+e4x8xx609F+
        \\YZ718L6n2ju2RzqTKcYpQMjsc1pHTQWlgjUjGVH0qbkr0BqJSKRMi+uBx3p8a5HYVD8yb32JY15FSKpx
        \\nisp6RuNbj1BzUyrnkmo6FEqrz7U/advHOazvcRHIuSazNXDpbSSJjeqErnpmrp6CueeXusahO5zKi8c
        \\7VrPuGklUiSQtkd6+po0YQs0edVrTd1cqeSoJOB0xUCxpnouAecV33e558rbH//S+KdmFHTk1btywUqc
        \\YNcEnfc9SGl7DyAJ1AHIParx+YZ4/Guea2OmC1dhGjQn5kXNQtbQFiWiTlfSoTa2G0nuU5bG2aQ7V2jP
        \\JU+1RSaXC2GjuApyOorX2slYz9lF3sV/7MmViFljaoJLG6SQbkyDXQqiZzyg1Yg8i4jBJjIBpsaPyXXB
        \\Psea1TTMJJqysaeh2u/UUfP3QCBXdQJtTpivFzKV3FH0WURtCT8zmPHcrhkRSOWro7O28rRYIgOwGB3r
        \\mnph4+bOxNvEy8kWFi+ULxwKzNRkMemSPj/WMT+FckNWdLv0KPhCMmGSZl6k1ulC3zY5x2+la4r+IyKH
        \\wH//0/nuIHB9c9KevUAHk18La60PtHuRy/64+lOGBniqXcOlhUIxwB+NSrynSpndFImQc4A7d6lQccdR
        \\WcyUyWMccDnPSpVAwM1nLYaeo5BjrUyjFTugJIwd2Kfgkc59qyTs7Axkigqao3qBkYdiMVpTeugHmF7b
        \\hbhl2/dJB/OofJBTHfp9K+ppTbimeZOK5issYG5W7VWdBnHXB65rrjJs5JLof//U+LYtu7leM+lSpxIR
        \\7VwO90eskrNkqZLo3PXHoausxI4wa557o2p6JitnOCoqvI3zEkdF5qIrUuW2ogO1iWHeibazIQncHA+l
        \\DT0aCyaaZGNm8kA9PSl2qy9SB78Veq1ZCs9BkOGUrj86zdQGbllVMAe1bQdpGE1eBo+FoCbgtxkY966+
        \\E4hOeo5rycxleR72VwcaRx+t/wCmeJ7WAdDIOPpzXbSpt/dkcRr+tZ4j3aVNLzNKOteo/QjuiY7Jm6Ej
        \\ANYnitvL05YRxwOf8/WuXDK8l6nVUlaLZb8NQeXpijgZB/M1oIpyPzx74pV2nUbHTVoJH//V+fYhgnnv
        \\Txy4GBXwse59m7kMyEzkj8qkQfKatdgewIo7nIqdQAnXms52RSehMoHHPapY1wMAgVnKzFtqSwjjg4qR
        \\VJHXIzWc2rDiPVeeD+FSDqKh2sBKo54p+Pl61jbQG9RrDIPNU7teT6VpCztYDzfxGskWtXESdN5Pp15q
        \\gN2GZpB0r6ig17OL8jz535miCSPdnaxHHpVV48D7xIB7iu2LOOS7H//W+MCoeIDcc5p4VhIMDkDvXnpq
        \\+p6zu0SwZZlVm6HJFWyRg89MdawmkmrG1NtpiMcY5OevFQ7AWOT0FSkkU9UKUPmEh8jt+VMdGLDLYAIz
        \\xUtrQfLo7Mj2SHjePrSspxgEk1rdGSTGJjymLEZArOjAd5GLHk9DW0NGznqa8qOj8IRHBbrnnmugu08u
        \\1ZiSMn868LGz/eH1GAVqKOW8LR/bfG4c8rCCx46HpXZspk88jHzMf04pY7eEfIjDO7nLz/yKmqh/sjwR
        \\EFwAemcVhamkmpTRxKpyCN2RWeFsveZ01FpbubsEaRWyqhAxnH5YpxIx8rf/AFuK5W3Jts2Wisf/1/n5
        \\SSxHOM+lP7jGa+EVz7R2IpATN1IIpwB55NaJ2FuhYzx3PvU69OQaio7sEiZOvfpU0YwmMVnJ26DRJH2G
        \\DipUyR361jN6FIeq8/0qUdBxWbkCRIg/D6U8j5e9Rza3ExrA8nmqt0Dkmri9BnnfjlSmvuwGQyhulYkr
        \\yL86DANfTYRp0o3PPr3UnYbBOWU4zz7VHIGIJVjkGu1x5Tl5ro//0Pi3fhgMHJPXFWCeQwLe9ec+jPXj
        \\1JIM7gw44qy+WPUjkcVjPdGsNmgdsNkjJFQ7mMhAB5FRHuXJ6WRIw+VwCc9KbtPy5JyCKgdmxhBDNj8s
        \\U1Cyr0J/rWultDOzTuMuSiWjlT97r7HFZ1nkk4bIPXiuiD3uc00rqzOy8Lw+XBuJPQcGrXiGYJYMwJHB
        \\xXz1d89U+sw8eWmkuxi/DGP/AEm+vHycYUE/jXXu6w2vzdcfiaMw1qpLsjnwi/dt+bKCn5nlw2W5Gacw
        \\GD2wB+dcq2O4AnyADoM80QLukUsp9f0qb6XHuf/R+fkOWNSfwjnivhUz7Nq2hFJ/retPA4PWrWuwul2L
        \\FjAA6VMMFeTms5PUpbEw6/hxUyfd4as5PUETRds9KlA+Xk96ym9FcaHJgGpOv1rPUpIkXg8mnNnGaz5r
        \\aCaEPeqtx1OT0rSL2sC1OG+ISquoQuT1UjP4/wD16wGEZUYGPevo8E26UThrpc7G7ICDzg+1ROmF+91O
        \\K7VKVrHNyxWx/9L4uuVAcH371JvKqScFPU1597pHqtWbZNZnc+QxI9atv8p4z9ayqPVI1pr3WyPBLDGf
        \\qKYnExyeQKlFPQXH7zgdetSk8rgEnis29i0lqxijLEjjt1poU7iVHHpVX3uRbsZl+2IvLX+I56U/TUUA
        \\KxGSfSulu0XY5oq80drpcZSzHvjpWd47fy9O2g8kjpXz0ZJ1kvM+skrUnbsSfDm1C+HlfJ/euXIPRq3b
        \\lleQRYBCg5HrSxk+au/IxwkbUokRw0u0cBFyR70wEEbm6sc/gK5YuyZ1PzFVgVG4ZIzmpbTaJMt07+3F
        \\Q9i7n//T+foic55yTipRkYBBxXwaPtXuRyZEg4pWII4qk7C6BFwAf51MhG31+lZ1Frca2LKHn8qlDY6L
        \\UNgl1Jo+2akQ9BWVR9xpDgffrUq+wrO7tdDsSIPUUpPHvUK1xMM8HA61WmwWOB+NXENjiPiMhE1sw9WH
        \\8q5vqRnjivosD/BXzOKv8QkKgZBA6ZpV27MkDOa7ObsYI//U+MdVGxlK9zninqd1sCQM45rzYaxR68vj
        \\YtgT5h6jvV6Q5X0+lZ1n7yLofCxhOenfFMTI3cdRzWV9DWw5ARI3qPSnMSqKCOSRUy6FRurjFLjPp9KA
        \\xx06n1q1qjO70Me6YtcOOcKcH1q9oqF5l75Oea6KtowOagnKol5neWcSJaocdgRzXGfEm53ERKfvEV89
        \\gvfxCPqcXLlw8/Q6fwkph0aCEg4VB/KrsDbmcnA4PWoxFnVkxUVaml5IgR9sMj4+ZzSTuTjcOB0/CsUt
        \\zo0VrhCQiF2GcAn/AD+dWLRlYZPQ8cVEk7aF+p//1fAIuvfOakxnr+NfBJ2SsfaN6jJRiUA9RSheCMfn
        \\VXEtgjUk/wBTVgfdBwOfSs5stbE6g7unYVLGpwAazYvUmjHHanqDx061lLazKuh6DHBFSID27VEthkin
        \\5cUHOPxqLvqJiEYziq8/FaQ8hHH/ABEVvIhYYyHNcsrSZG5RyOtfQYC3slfzOPEX5tAA+amHIjO31ruu
        \\rHNa7P8A/9b411QMIwSDnNR2xYQNkjnnkV5sLctj15JqRLZjBzweeSKuycHkD8qyq6tF0rqLI2OTnK5p
        \\sGWbBHQd6zWxo3qSdXLYxTpPvLnvjrWdr2LvuNYYUnj6Uxyu4/KMrVx6ky6GOGLSOwXIYmr9n58UQeFg
        \\svbcCRXTVty2ZzYZOVRcpvDW721tv9LsBIpAHmQNn9K4zxPqSX2sK6hljDDO6uHBYWKre0i9PxPTzDFS
        \\VDkmtX9x2mm65YG0REnTccAc1rx3EJgbbIpyvUGuDE0JxleSO+hXhUj7rGK/7uNcj1P6UmSU+fHPJrlS
        \\5bnXe9mA/wBSQDxzkfh/+qp7YbIipbaOufwrN7WLR//X8DTO7I9e9SJnAIHNfBPY+ze4yQEPnGacoHof
        \\amvIELCDnnqanXoBzUSaRSRMo5J744qRBxzUSelwRPEMingdsVk7pFLckA5p44OTUXuh2HqOKRskE4qV
        \\sKQADkYqvcj8aqD0shWOV8fqDYqc4w4rj5D365Fe7lz/AHdjlxC11CNhyRnp0pqkYOc9a9G/c5bLof/Q
        \\+OdUH7sDnOeKrREgEN6V5tN+6exUT5rlm1IC9ec9qssBg5xzjNYzdpJmkNtRhJzgflSRDqD6flU7FkqZ
        \\55+holblfUVk90aLYYxJH3agvGCQPkjJ6DFaw7GMtrmdYpkcg1q6fsEwB6Ct8Q73M8DpKLZruu+3ZM43
        \\ADNctfeHt120cEjO3U7scmuDCVvZNux7GLw31iNmypLoN5byByrYzzxVfzdTtXcxzSAD3r0oYinW0Z41
        \\TB1cPrBlyy8S6nF9+QOMba1LbxepwsyFcYztrnrZdCabgb0MzlCyqGrZ+IbK4U7bgDg8E4rXtL+CQBfM
        \\VgTn9BXi1sJOno0e5SxVOqrxZ//R8DiGScip0HOAOa+CfkfaDJV+fpRjBIxT6iHRjnIHFTAYXBIqZ7lK
        \\1rEygZxUsYI68Gsm7gkSQ59PwqZRxx681lK/LYaHpjI7U8ge1ZK3Qdxw5XpijAOelGoNCDPOOaguOf8A
        \\CnFCOa8cJu0uTI6EHH41xLou3gYBr3culaLXmc2JV7DIx8pXHFNAxknGc16b0OM//9L44v8A/V5wMiqy
        \\/dbI6j1rzKb0PYq7li2C4HHHrVmT5Rx9ayqN8yLppKIwEj6+lPhAGfzNQ9rmqexKvcAYxTTjeM88isty
        \\xhI3mqWrNwqADB5ranozCo9GQaeBjByR1q2GIzjj2rasryMaErRVieK/kjwHbIGOBVrSbtZNRmlfAB+U
        \\ZP0/wrinQsnKPY9eljVJqM9zYgMTMAjoRnoRUV3ptrMrl4UY+o4rzIzcHc9Nx5kZc/hu1lUlBszWPqHh
        \\Z1lYxHJHQZr0cPmElpI87E5dCptoZl1o9zADuVhwfaqqz39tIPLeVMDoPpXqUqsKyPHr0KuGfun/0/Bo
        \\Rzlh+lToOBXwGltD7RjJQcjtSqODn9RVLyEEY96nVflzis6l3YpaEigdscCpl5XqeKiaVgJIhn/61Sgc
        \\AdOaylqkyluPXv7U8gZx/Koih9R+ML1ppHynIoRLEAqKYZ6njFVHRXBnP+Lk3aXN0yFz+tcM6j15r2cv
        \\ejOfEdLjMDb94ZHaoyvy9O/Y16mqOQ//1PjfUcBcnjJ9KqggRldo579682krxPWqO0i1AM7c59OlWJMA
        \\/lWVTdGtJaNiLg89afCMkjOOO1ZtGu5IpCs+emf6Uxug6Y45rO3UruiFmKydvrVK8ZZLogAn+ldNOPU5
        \\pvox1pH+7JzhumKlVfkOckmnNq5MI2SGScE5HTBqWDcBkMvJ6CpuraFWd+w3ULqW3gMsb4fOOO1VNP8A
        \\FGoxsyy7JFA6kYNKGDp1Y+8aSzCrh5e7qjesPE9s8eJh5eRnIrShvbG7AMUqZ+teVVwU6TbWqPaw+OpV
        \\0lezJWgV4yAVYc8GqV5pFpMMyW+O+V+lc1KtKD906q1KMlaR/9XwqPg9e9SqOQQetfnyfc+0Y2UfOKFy
        \\B25q1K+grCx564FTL93rilMaRKvXtz7U9OnfrWbtbQdyaLoOtSr/AFrOSstCl2HLnPNP5z1qNEA9s4FM
        \\7daSVhMAcZzTJlOD1prYDC8VoTpdzjP+rbH5V5w/nDkj9a9rK2mnc5sVeysQxmYMd4wDUkLM3LZFeu0u
        \\hxan/9b44v8AG35cnnNVArKM+tefS+HU9WoveuizCQCBuOT61ZcnGcgmsZrVG1N3TGrk4x3qWBQGPUHF
        \\RJspa7kjAFmwOp6Y9qSXPyDtkVgnsa9yFxhWYrj2rJUtJcFgB75rqpSvc5K0bWSRetV2Rg98c8d6UZCs
        \\M8AZPNTLWTuVFWiiIgjcBnDY5NToCsZAyDnqKUrtJDitWUfETbYI1Ixz7ZNYkXyzMAMevHSuvDfCceK3
        \\NKGIG0Ppj73pVdi0F2MMQDj7pog7uSYTXKotGxYajeQwA/aHOAeG5zV6HxJLCdk8KuvTK8dvSvNq4OFV
        \\6aM9ajmM6SSlqj//1/DIOpHGaljG4cYH4V+e62PtWEi45pvzcjIwKuLsS9RYwM9s1Jj5Md88molqUnYl
        \\Xlue1SryKlpodiWLGB6GpBWU9FcEPQd6eBgjNRYpCn7opDyM0Ru9RMQdxxzSODVR12F6mTryFrWVcfeU
        \\j9K82ctvxxXrZY7XRjiF7qEjUHgkYFQuuCeB19K9dO5xSSsf/9D44uwSmM556VXkXMJHGenFeZTvoexN
        \\Ilg4bBOTjrip5uQcY4x2qJ3ckVDSLQ6MdCPpT4uGIHGOaze1jRJbkjFgDgYpjEgqxI7dqyWhpuQ3rkQS
        \\HjpWfaR9/wCf1rqp6RZy1Peki8MGMfNx7d6jc7Yyc4ye1JptjvorjBneDw2QMVPEHBIOFwR3qbXF5ox/
        \\EDl71U4ODiqDrjJABIrsoaRSRx19ZNmrbD/RgScAjsag1CF9pcBTxWMXaTNZRbirDrF3CbSQTg9f5U+Z
        \\QJxwFBA/lRZc1yrvlsf/0fD4fvE1MnYk/nX5/wBD7R7iP1yMdaQLzRF9LCa7hGvOf0qXHy9qUtxkgXnt
        \\UqDk0pK7sCfYkUcYA6VKnIFYzWha7jhT1Hes42TsC1FIyOlNYEU4oT8hB3pGzt68U1tYVzP1IZQ56Yrz
        \\e6UC5lUrwGOB+Nepl3xNGddXiV0Y8jGPw6U1slSCec9a9m6OCx//0vji/wAiMY45qux3Rbh/KvNprRHr
        \\1N2iW3z5gHY81ZnA3AnipqfErF01aDuPhwXAPHSpME7jyOK53pKxt9kT5vmB4IPHFMkwcEnkkVPkPpqU
        \\75zt8sDBJ+tNtVCt8x59q6rWi7HKneSuTxAhCAQOcc0yQEA4br2FRfVqxfK7LUYw4weCu3n1qbdiNmOM
        \\EgY9KV9CXo2YF+VMyNx8zE5qMgsrhccdq7obK5xT3aRdtTi2VmPGMdc+lWJgr5XAGMfrWElq7G8XsmUx
        \\C8ZJjOQQcgdakVXZxv4PbjvijmTJlBr7z//T8RjIGPc1KhXqPXivzzdH2bWoSD5sg4INJwRzz9aEw2BM
        \\dM5qTjb60SdykSA88enepEOOKU31EkTREdqkH54NZT1Ra0Hd/SnHip0Q/IVjwPWmsePehPqiWC9T1pHH
        \\B5oTaFYoaiOOn415tqm4X842jiRh+tenlvxMzrfCV05JLDHTgD3ppYFCB6/Svb1aOHbc/wD/1PjnUv8A
        \\Vct3qq53IMeleZDZM9ipu0SRYDAkkewqxI24+w6VM90EL2aJYCN5AbgY/lU0R+9z+FZS0N076DZSNzc5
        \\yc0xyoUfh25qG9mU7XZnXLZuTgnaKsW4zjqRnriuiStHQ5Y/GOxgEVFuwpBA9+MVKsytUOjILcZ7daNQ
        \\ZEt3O7k8fjU3ldDbVmc/cPm4QYA/rS8gMD2zz6139EcF7tli2lVIAhVsYPap45lZiFG08DnrWLT1Ztde
        \\6kidMGMZHGD3pkqjcOcZ447cVjF6o0nZxbP/1fElB7HOD1qVQOOtfnSVj7VsRwNx60Ywp4PFOCVwvoIg
        \\HB9e1SAAjGcUpa7AiQDkf0qRRxgZGaUrWuwJYwOByalXGB6A1nOzRS3FAI70/GSOtTtuMVunemHGKUe1
        \\iRRgk0hwKqPkDZS1DkYFed+JEEWs3Q5GHz9M816GX6VPkZ1V7pQibOck8jrUbgDIA4r3epwJ6an/1vjf
        \\U9vl43YyelUwR5RGTxx0rzaauj1qrSlckiA3D5j071aYjccnHSlJXaHDZsntzkY3Z96lQjnnt9K55I3T
        \\GsRyDnI9ajfKKOemDxio7Iq+7M3JeVieSecYq7AMKF3Fj6V0zVlaxzQfvXGDpy2McdajjydwIO2h2Hd6
        \\ND41G8nAGMdD1qLV2zAFORl+R1qEtVcTdkzBl5vSCMgNwKlVG3MFJ4967r6I4bO7JY1BjJJ7Y6dDVqyQ
        \\CYkqTjvWEn7rN1unYtYQLntg9+tV2+aQBlbPTHrxWNPzNqux/9fxWMDP41IoUYr87WzPs3uEgBJ9uKAB
        \\tINCSbDoJGAMcdKkAG04/KiSXQpPQkXGcY7VINp56VLBbksYBxUgAx0rOadrDT7C45pxA4wKVkUhX7ZF
        \\NODzRG1iGAA5NIwGeB1FNLuBTvEBI7V5/wCNFP8Awkl1tIABUdP9kV35cl7VehFbWBlxbNuD8x9aY20Y
        \\xjOa96xwWstD/9D451XAhBOOTxVRlURdOa8ymrI9epu2SW23cMgDHb1qw4BcrgY9KJ25kOn8LLFsArYG
        \\McVIu3GdvOOTWLV2axeliOYgM+FzmoL1isAwME4GKVloDvqVoI9zEEAMMGrbIAmFUdcZrSbS0MqcWQBg
        \\0WMg4PalhCFCdpHWiXUFZtaDtqhywBwMY9Ko6sR5oXPTn2p09WianVIyEYebwMEnPNTL5eXBA4Hautp6
        \\WONSWt0TQMhUgjKj1q5bhQWKMDwBxWE20mbws3ElXy9pUEDqMd6hfaHUgE7B2HtWUO7NKiVrI//R8Vj4
        \\br37VMuT9TX55HY+ze+gMM5PSkzwR1AoWu4IRRg9akPC8HpSlfRFLXYeCN3TkipV60ulmBJGeR71IvTP
        \\Ws5K6Ghwp3FQkMH6elNJ461didOoq9SaRjxSjqwuVbgZkH1rzrxWwk8QXj9hIR+XFejl1nVt5EV/gM2I
        \\qCTjPTH50x+eRxya961tzzt9j//S+O9WJ+zjgDmqJYGDJYZNedSSaPXqu0tew+L7wPTvmrBO5x7Y5qZf
        \\EnYUPhZdhUZyO3pTgcOxGOR0rnbu7M6fhK9yVEvPy59O9QX75VBjnIoS+ETa95DLbdu6nnp7VYGSMk59
        \\vxrWemxlTZCvMe4BTg/nSRKHVsjGfpSe90C1VmTsG2H2x3rF1J1eVxgcHr+FVQWtyK7srFGAgOrHqDnp
        \\7VPGNzO/O3kkCut7pnGno0idCCNyt6Crca5ZiDjpgVzXsnc6X71rDyBgcbtucn8KhjBMpOfrz7VlTdtT
        \\Sqm7JH//2Q==
    ;

    const codecs = std.base64.standard;
    const dec = codecs.decoderWithIgnore("\n");

    // const decoder = std.base64.Base64Decoder.init(std.base64.standard.alphabet_chars, null);
    var buffer: [0x10000]u8 = undefined;
    const decoded = buffer[0..try dec.calcSizeUpperBound(base64EncodedImage.len)];
    _ = try dec.decode(decoded, base64EncodedImage);

    // std.log.warn("\n\ndecoded_data.len: {d}\n\n", .{decoded_data.len});

    var reader_val2 = std.Io.Reader.fixed(decoded);
    const reader2: *std.Io.Reader = &reader_val2;

    // Attempt to decode the JPEG image.
    const img = try decode(testing.allocator, reader2);
    img.free(testing.allocator);
}

test "Issue56724: Decode truncated JPEG should return UnexpectedEof" {
    const allocator = testing.allocator;

    // **1. Read the JPEG File**
    const file_path = "src/testdata/video-001.jpeg";

    // Open the file in read-only mode
    const file_data = try std.fs.cwd().readFileAlloc(allocator, file_path, 17000000);
    defer allocator.free(file_data);

    // **2. Truncate the Data to First 24 Bytes**
    const truncated_data = file_data[0..24];
    var reader_val3 = std.Io.Reader.fixed(truncated_data);
    const reader3: *std.Io.Reader = &reader_val3;

    // **3. Attempt to Decode the Truncated JPEG Data**
    const decode_result = decode(allocator, reader3);

    try testing.expectError(error.UnexpectedEof, decode_result);
}

test "bad restart marker" {
    const allocator = testing.allocator;

    // **1. Read the JPEG File**
    const file_path = "src/testdata/video-001.restart2.jpeg";

    // Open the file in read-only mode
    const file_data = try std.fs.cwd().readFileAlloc(allocator, file_path, 17000000);
    defer allocator.free(file_data);

    try testing.expectEqual(file_data.len, 4855);
    try testing.expect(file_data[2816] == 0xff and file_data[2817] == 0xd1);

    const prefix = file_data[0..2816];
    const suffix = file_data[2816..];

    const test_cases = [_][]const u8{
        "PASS:",
        "PASS:\x00",
        "PASS:\x61",
        "PASS:\x61\x62\x63\xff\x00\x64",
        "PASS:\xff",
        "PASS:\xff\x00",
        "PASS:\xff\xff\xff\x00\xff\x00\x00\xff\xff\xff",

        "FAIL:\xff\x03",
        "FAIL:\xff\xd5",
        "FAIL:\xff\xff\xd5",
    };
    for (test_cases) |tc| {
        const want_pass = std.mem.eql(u8, tc[0..5], "PASS:");
        const infix = tc[5..];

        var data = std.ArrayListUnmanaged(u8){};
        defer data.deinit(allocator);

        try data.appendSlice(allocator, prefix);
        try data.appendSlice(allocator, infix);
        try data.appendSlice(allocator, suffix);

        const reader = readerFromSlice(data.items);

        const result = decode(allocator, reader);

        if (want_pass) {
            const img = try result;
            img.free(allocator);
        } else {
            try testing.expectError(error.BadRSTMarker, result);
        }
    }
}
