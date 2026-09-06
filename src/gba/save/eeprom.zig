//! Serial EEPROM save backends.

const std = @import("std");
const backend = @import("backend.zig");
const gba = @import("../gba.zig");

const eeprom_address = 0x0dff_ff00;
const block_len = 8;
const max_ready_polls = 200_000;

fn EepromBackend(comptime capacity_bytes: usize, comptime address_bits: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = capacity_bytes;
        pub const erase_alignment = block_len;
        pub const Error = backend.Error;

        pub fn init() Self {
            return .{};
        }

        pub fn read(_: *Self, offset: usize, output: []u8) Error!void {
            if (offset > capacity or output.len > capacity - offset) return error.OutOfBounds;
            const original_dma = gba.mem.dma[3];
            defer gba.mem.dma[3] = original_dma;
            var copied: usize = 0;
            while (copied < output.len) {
                const block = (offset + copied) / block_len;
                var bytes: [block_len]u8 = undefined;
                try readBlock(block, &bytes);
                const within_block = (offset + copied) % block_len;
                const count = @min(output.len - copied, block_len - within_block);
                @memcpy(output[copied .. copied + count], bytes[within_block .. within_block + count]);
                copied += count;
            }
        }

        pub fn write(_: *Self, offset: usize, input: []const u8) Error!void {
            if (offset > capacity or input.len > capacity - offset) return error.OutOfBounds;
            const original_dma = gba.mem.dma[3];
            defer gba.mem.dma[3] = original_dma;
            var written: usize = 0;
            while (written < input.len) {
                const block = (offset + written) / block_len;
                var bytes: [block_len]u8 = undefined;
                try readBlock(block, &bytes);
                const within_block = (offset + written) % block_len;
                const count = @min(input.len - written, block_len - within_block);
                @memcpy(bytes[within_block .. within_block + count], input[written .. written + count]);
                try writeBlock(block, &bytes);
                written += count;
            }
        }

        pub fn erase(self: *Self, offset: usize, len: usize) Error!void {
            if (offset > capacity or len > capacity - offset) return error.OutOfBounds;
            const blank: [block_len]u8 = @splat(0xff);
            var erased: usize = 0;
            while (erased < len) {
                const count = @min(blank.len, len - erased);
                try self.write(offset + erased, blank[0..count]);
                erased += count;
            }
        }

        fn dataPort() *volatile u16 {
            return @ptrFromInt(eeprom_address);
        }

        fn beginTransaction() gba.mem.WaitControl {
            const original = gba.mem.wait_ctrl.*;
            var wait = original;
            wait.first_2 = .cycles_8;
            wait.second_2 = .cycles_8;
            gba.mem.wait_ctrl.* = wait;
            return original;
        }

        fn readBlock(block: usize, output: *[block_len]u8) Error!void {
            const original_wait = beginTransaction();
            defer gba.mem.wait_ctrl.* = original_wait;

            var command: [2 + address_bits + 1]u16 = undefined;
            command[0] = 1;
            command[1] = 1;
            for (0..address_bits) |index| {
                const shift: std.math.Log2Int(usize) = @intCast(address_bits - index - 1);
                command[2 + index] = @intCast((block >> shift) & 1);
            }
            command[command.len - 1] = 0;
            transferWrite(&command);

            var raw: [68]u16 = undefined;
            transferRead(&raw);
            output.* = @splat(0);
            for (0..64) |index| {
                const bit: u8 = @intCast(raw[4 + index] & 1);
                output[index / 8] = (output[index / 8] << 1) | bit;
            }
        }

        fn writeBlock(block: usize, input: *const [block_len]u8) Error!void {
            const original_wait = beginTransaction();
            defer gba.mem.wait_ctrl.* = original_wait;

            var command: [2 + address_bits + 64 + 1]u16 = undefined;
            command[0] = 1;
            command[1] = 0;
            for (0..address_bits) |index| {
                const shift: std.math.Log2Int(usize) = @intCast(address_bits - index - 1);
                command[2 + index] = @intCast((block >> shift) & 1);
            }
            for (0..64) |index| {
                const shift: u3 = @intCast(7 - (index % 8));
                command[2 + address_bits + index] = (input[index / 8] >> shift) & 1;
            }
            command[command.len - 1] = 0;
            transferWrite(&command);

            for (0..max_ready_polls) |_| {
                if ((dataPort().* & 1) != 0) return;
            }
            return error.Timeout;
        }

        fn transferWrite(bits: []const u16) void {
            gba.mem.dma[3].source = @ptrCast(bits.ptr);
            gba.mem.dma[3].dest = @ptrCast(dataPort());
            gba.mem.dma[3].count = @intCast(bits.len);
            gba.mem.dma[3].ctrl = .{
                .source = .increment,
                .dest = .fixed,
                .size = .bits_16,
                .enabled = true,
            };
        }

        fn transferRead(bits: []u16) void {
            gba.mem.dma[3].source = @ptrCast(dataPort());
            gba.mem.dma[3].dest = @ptrCast(bits.ptr);
            gba.mem.dma[3].count = @intCast(bits.len);
            gba.mem.dma[3].ctrl = .{
                .source = .fixed,
                .dest = .increment,
                .size = .bits_16,
                .enabled = true,
            };
        }
    };
}

/// Backend for 512-byte (4 Kbit) EEPROM.
pub const Eeprom512Backend = EepromBackend(512, 6);
/// Backend for 8 KiB (64 Kbit) EEPROM.
pub const Eeprom8kBackend = EepromBackend(8 * 1024, 14);
