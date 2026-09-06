const std = @import("std");
const save = @import("root.zig");
const layout = @import("layout.zig");

const FakeBackend = struct {
    pub const capacity = 1024;
    pub const erase_alignment = 1;
    pub const Error = save.backend.Error || error{InjectedFailure};

    bytes: [capacity]u8 = @splat(0xff),
    /// Number of writable bytes left before the next write or erase fails.
    fail_after: ?usize = null,

    pub fn init() FakeBackend {
        return .{};
    }

    pub fn read(self: *FakeBackend, offset: usize, output: []u8) Error!void {
        if (offset > capacity or output.len > capacity - offset) return error.OutOfBounds;
        @memcpy(output, self.bytes[offset .. offset + output.len]);
    }

    pub fn write(self: *FakeBackend, offset: usize, input: []const u8) Error!void {
        if (offset > capacity or input.len > capacity - offset) return error.OutOfBounds;
        const count = self.writableBytes(input.len);
        @memcpy(self.bytes[offset .. offset + count], input[0..count]);
        if (count != input.len) return error.InjectedFailure;
    }

    pub fn erase(self: *FakeBackend, offset: usize, len: usize) Error!void {
        if (offset > capacity or len > capacity - offset) return error.OutOfBounds;
        const count = self.writableBytes(len);
        @memset(self.bytes[offset .. offset + count], 0xff);
        if (count != len) return error.InjectedFailure;
    }

    fn writableBytes(self: *FakeBackend, requested: usize) usize {
        if (self.fail_after) |*remaining| {
            const count = @min(remaining.*, requested);
            remaining.* -= count;
            return count;
        }
        return requested;
    }
};

const Saves = save.Manager(FakeBackend, .{
    .slot_count = 2,
    .summary_len = 4,
    .payload_len = 32,
});

const first_summary = [_]u8{ 1, 2, 3, 4 };
const second_summary = [_]u8{ 5, 6, 7, 8 };
const first_payload = [_]u8{0x11} ** 32;
const second_payload = [_]u8{0x22} ** 32;

test "slots store summaries and payloads" {
    var saves = try Saves.init(.{ .game_id = "org.ziggba.save-test" });
    try std.testing.expectEqual(save.SlotStatus.empty, try saves.slotStatus(0, null));

    try saves.store(0, &first_summary, &first_payload);
    var summary: [4]u8 = undefined;
    var payload: [32]u8 = undefined;
    try std.testing.expectEqual(save.SlotStatus.valid, try saves.slotStatus(0, &summary));
    try std.testing.expectEqualSlices(u8, &first_summary, &summary);
    try saves.load(0, &payload);
    try std.testing.expectEqualSlices(u8, &first_payload, &payload);

    try saves.eraseSlot(0);
    try std.testing.expectEqual(save.SlotStatus.empty, try saves.slotStatus(0, null));
    try std.testing.expectError(error.EmptySlot, saves.load(0, &payload));
}

test "interrupted writes preserve the preceding valid record" {
    var original = try Saves.init(.{ .game_id = "org.ziggba.save-test" });
    try original.store(0, &first_summary, &first_payload);

    const bytes_needed = Saves.capacity().record_stride + layout.header_size + first_summary.len + first_payload.len + 1;
    for (0..bytes_needed) |budget| {
        var interrupted = original;
        interrupted.backend.fail_after = budget;
        const stored = interrupted.store(0, &second_summary, &second_payload);
        interrupted.backend.fail_after = null;

        var payload: [32]u8 = undefined;
        if (stored) |_| {
            try interrupted.load(0, &payload);
            try std.testing.expectEqualSlices(u8, &second_payload, &payload);
        } else |err| {
            try std.testing.expectEqual(error.InjectedFailure, err);
            try interrupted.load(0, &payload);
            try std.testing.expectEqualSlices(u8, &first_payload, &payload);
        }
    }
}

test "corrupt payloads and incompatible formats are reported" {
    var saves = try Saves.init(.{ .game_id = "org.ziggba.save-test" });
    try saves.store(0, &first_summary, &first_payload);
    saves.backend.bytes[layout.header_size] ^= 1;
    try std.testing.expectEqual(save.SlotStatus.corrupt, try saves.slotStatus(0, null));

    var payload: [32]u8 = undefined;
    try std.testing.expectError(error.CorruptSlot, saves.load(0, &payload));

    var compatible = try Saves.init(.{ .game_id = "org.ziggba.save-test" });
    try compatible.store(1, &first_summary, &first_payload);
    var newer_format = try Saves.init(.{
        .game_id = "org.ziggba.save-test",
        .format_version = 2,
    });
    newer_format.backend = compatible.backend;
    try std.testing.expectEqual(save.SlotStatus.incompatible, try newer_format.slotStatus(1, null));
    try std.testing.expectError(error.IncompatibleSlot, newer_format.load(1, &payload));
}
