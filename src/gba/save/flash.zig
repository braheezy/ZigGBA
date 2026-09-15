//! AMD-compatible GBA cartridge Flash save backends.

const backend = @import("backend.zig");

const flash_address = 0x0e00_0000;
const bank_size = 0x10000;
const sector_size = 0x1000;
const unlock_1 = 0x5555;
const unlock_2 = 0x2aaa;
const max_poll_count = 1_000_000;

/// Common Flash implementation for one or two 64 KiB banks.
fn FlashBackend(comptime bank_count: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = bank_count * bank_size;
        pub const erase_alignment = sector_size;
        pub const Error = backend.Error;

        current_bank: u1 = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn read(self: *Self, offset: usize, output: []u8) Error!void {
            if (offset > capacity or output.len > capacity - offset) return error.OutOfBounds;
            var copied: usize = 0;
            while (copied < output.len) {
                const absolute = offset + copied;
                const bank = absolute / bank_size;
                const bank_offset = absolute % bank_size;
                const count = @min(output.len - copied, bank_size - bank_offset);
                // Reading from Flash uses the selected bank. The 64 KiB
                // backend never has to switch; the 128 KiB backend switches
                // before each cross-bank portion of the read.
                try self.selectBank(@intCast(bank));
                const data = selectedMemory();
                for (output[copied .. copied + count], 0..) |*byte, index| byte.* = data[bank_offset + index];
                copied += count;
            }
        }

        pub fn write(self: *Self, offset: usize, input: []const u8) Error!void {
            if (offset > capacity or input.len > capacity - offset) return error.OutOfBounds;
            for (input, 0..) |byte, index| try self.programByte(offset + index, byte);
            try self.verify(offset, input);
        }

        pub fn erase(self: *Self, offset: usize, len: usize) Error!void {
            if (offset > capacity or len > capacity - offset) return error.OutOfBounds;
            if (offset % sector_size != 0 or len % sector_size != 0) return error.EraseFailed;
            var erased: usize = 0;
            while (erased < len) {
                try self.eraseSector(offset + erased);
                erased += sector_size;
            }
        }

        fn memory() linksection(".iwram") *volatile [bank_size]u8 {
            return @ptrFromInt(flash_address);
        }

        fn selectedMemory() linksection(".iwram") *volatile [bank_size]u8 {
            return memory();
        }

        fn unlock() linksection(".iwram") void {
            const data = selectedMemory();
            data[unlock_1] = 0xaa;
            data[unlock_2] = 0x55;
        }

        fn selectBank(self: *Self, bank: u1) linksection(".iwram") Error!void {
            if (bank_count == 1) {
                if (bank != 0) return error.OutOfBounds;
                return;
            }
            if (self.current_bank == bank) return;
            unlock();
            selectedMemory()[unlock_1] = 0xb0;
            selectedMemory()[0] = bank;
            self.current_bank = bank;
        }

        fn programByte(self: *Self, absolute_offset: usize, value: u8) linksection(".iwram") Error!void {
            const bank: u1 = @intCast(absolute_offset / bank_size);
            const offset = absolute_offset % bank_size;
            try self.selectBank(bank);
            unlock();
            selectedMemory()[unlock_1] = 0xa0;
            selectedMemory()[offset] = value;
            try self.waitForValue(offset, value);
        }

        fn eraseSector(self: *Self, absolute_offset: usize) linksection(".iwram") Error!void {
            const bank: u1 = @intCast(absolute_offset / bank_size);
            const offset = absolute_offset % bank_size;
            try self.selectBank(bank);
            unlock();
            selectedMemory()[unlock_1] = 0x80;
            unlock();
            selectedMemory()[offset] = 0x30;
            try self.waitForValue(offset, 0xff);
        }

        fn waitForValue(_: *Self, offset: usize, expected: u8) linksection(".iwram") Error!void {
            const data = selectedMemory();
            for (0..max_poll_count) |_| {
                if (data[offset] == expected) return;
            }
            return error.Timeout;
        }

        fn verify(self: *Self, offset: usize, expected: []const u8) Error!void {
            var actual: [64]u8 = undefined;
            var verified: usize = 0;
            while (verified < expected.len) {
                const count = @min(actual.len, expected.len - verified);
                try self.read(offset + verified, actual[0..count]);
                for (expected[verified .. verified + count], actual[0..count]) |expected_byte, actual_byte| {
                    if (expected_byte != actual_byte) return error.VerifyFailed;
                }
                verified += count;
            }
        }
    };
}

/// Backend for 64 KiB Flash cartridges.
pub const Flash64Backend = FlashBackend(1);
/// Backend for 128 KiB Flash cartridges with two 64 KiB banks.
pub const Flash128Backend = FlashBackend(2);
