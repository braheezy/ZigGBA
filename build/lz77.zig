const std = @import("std");

/// Compresses `src` using the Game Boy Advance LZ77 format (SWI 0x11/0x12).
/// The returned slice is allocated from `allocator` and must be freed by the caller.
///
/// Format:
///   0x10             – magic byte
///   3-byte little-endian – size of the *decompressed* data
///   body             – groups of 8 blocks preceded by a flag byte.
///                      flag bit = 0 → raw byte
///                      flag bit = 1 → 2-byte back-reference (length 3-18,
///                                                 distance 1-0x1000)
pub fn compress(allocator: std.mem.Allocator, src: []const u8, vram_safe: bool) ![]u8 {
    if (src.len > 0xFFFFFF)
        return error.DataTooLarge;

    var out_list = std.ArrayList(u8).empty;
    errdefer out_list.deinit(allocator);

    // --- header ---
    try out_list.append(allocator, 0x10); // magic
    try out_list.append(allocator, @as(u8, @truncate(src.len & 0xFF)));
    try out_list.append(allocator, @as(u8, @truncate((src.len >> 8) & 0xFF)));
    try out_list.append(allocator, @as(u8, @truncate((src.len >> 16) & 0xFF)));

    var src_off: usize = 0;
    var buffered_blocks: u8 = 0; // 0-7
    var control_index: usize = undefined; // index of current control byte in out_list

    control_index = try startControlByte(allocator, &out_list);

    while (src_off < src.len) {
        // Search for longest match in the sliding window (max 0x1000 bytes back, max 18 bytes long)
        var best_len: usize = 0;
        var best_dist: usize = 0;
        const window_limit = @min(src_off, 0x1000);
        if (window_limit > 0) {
            const max_len_allowed = @min(18, src.len - src_off);
            var dist: usize = 1; // distance is at least 1
            while (dist <= window_limit) : (dist += 1) {
                if (vram_safe and (dist & 1) == 1) {
                    // For VRAM-safe data, skip odd distances because VRAM decompression
                    // writes 16-bit halfwords; overlapping by one byte is unsafe.
                    continue;
                }
                var match_len: usize = 0;
                while (match_len < max_len_allowed and src[src_off - dist + match_len] == src[src_off + match_len]) : (match_len += 1) {}
                if (match_len > best_len) {
                    best_len = match_len;
                    best_dist = dist;
                    if (best_len == max_len_allowed) break; // can't do better
                }
            }
        }

        if (best_len >= 3) {
            // encode compressed block
            const distance_minus1 = best_dist - 1;
            const length_minus3 = best_len - 3;
            const first_byte: u8 = @intCast(((length_minus3 << 4) & 0xF0) | ((distance_minus1 >> 8) & 0x0F));
            const second_byte: u8 = @intCast(distance_minus1 & 0xFF);
            try out_list.append(allocator, first_byte);
            try out_list.append(allocator, second_byte);

            // set corresponding flag bit (bit7..bit0)
            out_list.items[control_index] |= @as(u8, @intCast(1)) << @intCast(7 - buffered_blocks);

            src_off += best_len;
        } else {
            // raw literal
            try out_list.append(allocator, src[src_off]);
            src_off += 1;
        }

        buffered_blocks += 1;
        if (buffered_blocks == 8 or src_off == src.len) {
            // move to next control byte group
            buffered_blocks = 0;
            if (src_off < src.len) {
                control_index = try startControlByte(allocator, &out_list);
            }
        }
    }

    // Align total size to 4 bytes so embedded data can be 4-aligned, as is customary for GBA assets.
    const aligned_len = std.mem.alignForward(usize, out_list.items.len, 4);
    const pad_needed = aligned_len - out_list.items.len;
    for (0..pad_needed) |_| try out_list.append(allocator, 0);

    return out_list.toOwnedSlice(allocator);
}

fn startControlByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !usize {
    const idx = out.*.items.len;
    try out.*.append(allocator, 0); // placeholder control byte
    return idx;
}
