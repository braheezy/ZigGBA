const std = @import("std");
pub const gba = @import("../gba.zig");

pub const Case = struct {
    x: i16,
    y: i16,
    expected: u16,
    tolerance: u16 = 0,

    pub fn accepts(self: Case, actual: u16) bool {
        // Compare across the wrap from 0xffff to zero as well.
        return @min(actual -% self.expected, self.expected -% actual) <= self.tolerance;
    }
};

// Shared host/ROM cases. Angles use 65536 units per turn.
// Cartesian product covers the origin, axes, diagonals, every quadrant,
// both dominant-axis branches, and signed input limits. This is branch and
// boundary coverage, not an exhaustive test of all 2^32 input pairs.
pub const cases = blk: {
    @setEvalBranchQuota(100000);
    const inputs = [_]i16{ -32768, -32767, -16384, -2, -1, 0, 1, 2, 16384, 32767 };
    var result: [inputs.len * inputs.len]Case = undefined;
    var index: usize = 0;
    for (inputs) |x| {
        for (inputs) |y| {
            const exact = x == 0 or y == 0 or @abs(@as(i32, x)) == @abs(@as(i32, y));
            const angle = if (x == 0 and y == 0) 0 else std.math.atan2(@as(f64, y), @as(f64, x));
            const units: i32 = @intFromFloat(@round(angle * (32768.0 / std.math.pi)));
            result[index] = .{
                .x = x,
                .y = y,
                .expected = @truncate(@as(u32, @bitCast(units))),
                // The BIOS uses an integer approximation. Four angle units
                // (~0.022 degrees) allow its quantization error off-axis.
                .tolerance = if (exact) 0 else 4,
            };
            index += 1;
        }
    }
    break :blk result;
};

test "BIOS arctan2 axes quadrants and signed boundaries" {
    for (cases) |case| {
        const actual = gba.bios.arctan2(case.x, case.y).value;
        if (!case.accepts(actual)) {
            std.debug.print("arctan2({d}, {d}): expected {x}, got {x}, tolerance {d}\n", .{
                case.x, case.y, case.expected, actual, case.tolerance,
            });
            return error.TestUnexpectedResult;
        }
    }
}
