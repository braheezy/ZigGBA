//! Stable, byte-oriented save-record encoding.

const std = @import("std");
const crc32 = @import("crc32.zig");

/// The record schema implemented by this version of ZigGBA.
pub const schema_version: u16 = 1;
/// The number of bytes in every encoded record header.
pub const header_size = 48;
/// The byte position of the write-once record state.
pub const state_offset = 41;
const header_crc_offset = 44;
const magic = "ZGGBASAV";

/// Whether a committed record contains game data or records an empty slot.
pub const Kind = enum(u8) {
    data = 1,
    empty = 2,
};

/// Record lifecycle markers. They only clear bits, permitting the same
/// transition on Flash media without another erase operation.
pub const State = enum(u8) {
    writing = 0x7f,
    valid = 0x3f,
    empty = 0x1f,
};

/// Decoded fields from a record header. Data bytes follow the header.
pub const Header = struct {
    format_version: u16,
    game_id_hash: u64,
    slot_index: u16,
    summary_len: u16,
    payload_len: u32,
    generation: u32,
    summary_crc: u32,
    payload_crc: u32,
    kind: Kind,
    state: State,
};

/// Encode a header. The checksum intentionally excludes `state`, since that
/// byte is changed from `writing` to its final committed value last.
pub fn encode(header: Header, output: *[header_size]u8) void {
    output.* = @splat(0xff);
    @memcpy(output[0..magic.len], magic);
    std.mem.writeInt(u16, output[8..10], schema_version, .little);
    std.mem.writeInt(u16, output[10..12], header.format_version, .little);
    std.mem.writeInt(u64, output[12..20], header.game_id_hash, .little);
    std.mem.writeInt(u16, output[20..22], header.slot_index, .little);
    std.mem.writeInt(u16, output[22..24], header.summary_len, .little);
    std.mem.writeInt(u32, output[24..28], header.payload_len, .little);
    std.mem.writeInt(u32, output[28..32], header.generation, .little);
    std.mem.writeInt(u32, output[32..36], header.summary_crc, .little);
    std.mem.writeInt(u32, output[36..40], header.payload_crc, .little);
    output[40] = @intFromEnum(header.kind);
    output[state_offset] = @intFromEnum(header.state);
    std.mem.writeInt(u32, output[header_crc_offset..][0..4], 0, .little);
    std.mem.writeInt(u32, output[header_crc_offset..][0..4], headerChecksum(output), .little);
}

/// Decode and validate a header. This does not validate the record payload.
pub fn decode(input: *const [header_size]u8) !Header {
    if (!std.mem.eql(u8, input[0..magic.len], magic)) return error.InvalidHeader;
    if (std.mem.readInt(u16, input[8..10], .little) != schema_version) return error.InvalidHeader;
    const stored_checksum = std.mem.readInt(u32, input[header_crc_offset..][0..4], .little);
    if (stored_checksum != headerChecksum(input)) return error.InvalidHeader;

    const kind = switch (input[40]) {
        @intFromEnum(Kind.data) => Kind.data,
        @intFromEnum(Kind.empty) => Kind.empty,
        else => return error.InvalidHeader,
    };
    const state = switch (input[state_offset]) {
        @intFromEnum(State.writing) => State.writing,
        @intFromEnum(State.valid) => State.valid,
        @intFromEnum(State.empty) => State.empty,
        else => return error.InvalidHeader,
    };
    return .{
        .format_version = std.mem.readInt(u16, input[10..12], .little),
        .game_id_hash = std.mem.readInt(u64, input[12..20], .little),
        .slot_index = std.mem.readInt(u16, input[20..22], .little),
        .summary_len = std.mem.readInt(u16, input[22..24], .little),
        .payload_len = std.mem.readInt(u32, input[24..28], .little),
        .generation = std.mem.readInt(u32, input[28..32], .little),
        .summary_crc = std.mem.readInt(u32, input[32..36], .little),
        .payload_crc = std.mem.readInt(u32, input[36..40], .little),
        .kind = kind,
        .state = state,
    };
}

/// Hash a game identifier using FNV-1a. This is for accidental cross-game
/// save detection, not cryptographic authentication.
pub fn gameIdHash(id: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (id) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}

/// True when `candidate` is newer than `current`, including across one
/// unsigned sequence-number wraparound.
pub fn isNewerGeneration(candidate: u32, current: u32) bool {
    return candidate != current and @as(i32, @bitCast(candidate -% current)) > 0;
}

fn headerChecksum(input: *const [header_size]u8) u32 {
    var crc: crc32.Crc32 = .{};
    for (input, 0..) |byte, index| {
        if (index == state_offset or (index >= header_crc_offset and index < header_crc_offset + 4)) continue;
        crc.updateByte(byte);
    }
    return crc.final();
}

test "record state can be committed without invalidating the header checksum" {
    const std_testing = @import("std").testing;
    var bytes: [header_size]u8 = undefined;
    encode(.{
        .format_version = 2,
        .game_id_hash = gameIdHash("test"),
        .slot_index = 1,
        .summary_len = 8,
        .payload_len = 16,
        .generation = 4,
        .summary_crc = 1,
        .payload_crc = 2,
        .kind = .data,
        .state = .writing,
    }, &bytes);
    bytes[state_offset] = @intFromEnum(State.valid);
    const decoded = try decode(&bytes);
    try std_testing.expectEqual(State.valid, decoded.state);
    try std_testing.expect(isNewerGeneration(0, std.math.maxInt(u32)));
}
