//! Access to the key control and status registers should
//! go through the functions in this module.
//!
//! Keys are active low, which doesn't play well intuitively
//! with checking them. These functions abstract that conversion
const std = @import("std");
const gba = @import("gba.zig");
const TriState = gba.utils.TriState;

// TODO: Maybe create an enumset that is "active low"
// or just wrap this one
pub const Keys = std.EnumSet(Key);

var prev_input: Keys = .{};
var curr_input: Keys = .{};

const reg_keyinput: *align(2) const volatile u10 = @ptrFromInt(gba.mem.io + 0x130);

pub const Key = enum {
    A,
    B,
    select,
    start,
    right,
    left,
    up,
    down,
    R,
    L,
};

pub const Control = packed struct(u16) {
    const Condition = enum(u1) {
        any = 0,
        all = 1,
    };

    keys_raw: Keys,
    _: u4,
    interrupt: bool,
    op: Condition,

    pub fn getKeys(self: Control) Keys {
        return self.keys_raw.complement();
    }

    pub fn setKeys(self: *Control, keys: Keys) void {
        self.keys_raw = keys.complement();
    }
};

/// Allows reading the D-pad and shoulders as connected axes
/// that can be read as -1, 0, or 1.
///
/// Negative axes are Left, Up, and L.
pub const Axis = enum {
    horizontal,
    vertical,
    shoulders,
};

/// Get the current value of this axis. Returns 0 if both buttons
/// or neither are pressed.
pub fn getAxis(axis: Axis) TriState {
    return switch (axis) {
        .horizontal => TriState.get(isKeyPressed(.left), isKeyPressed(.right)),
        .vertical => TriState.get(isKeyPressed(.up), isKeyPressed(.down)),
        .shoulders => TriState.get(isKeyPressed(.L), isKeyPressed(.R)),
    };
}

pub fn getAxisJustChanged(axis: Axis) TriState {
    return switch (axis) {
        .horizontal => TriState.get(isKeyJustPressed(.left), isKeyJustPressed(.right)),
        .vertical => TriState.get(isKeyJustPressed(.up), isKeyJustPressed(.down)),
        .shoulders => TriState.get(isKeyJustPressed(.L), isKeyJustPressed(.R)),
    };
}

/// Update cached input with current values.
pub fn poll() Keys {
    prev_input = curr_input;
    curr_input = .{ .bits = .{ .mask = ~reg_keyinput.* } };
    return curr_input;
}

pub fn currentInput() Keys {
    return curr_input;
}

pub fn isKeyPressed(key: Key) bool {
    return curr_input.contains(key);
}

pub fn isKeyHeld(key: Key) bool {
    return curr_input.intersectWith(prev_input).contains(key);
}

pub fn isKeyChanged(key: Key) bool {
    return prev_input.xorWith(curr_input).contains(key);
}

pub fn isComboPressed(combo: Keys) bool {
    return combo.subsetOf(curr_input);
}

pub fn isComboHeld(combo: Keys) bool {
    return combo.subsetOf(curr_input.intersectWith(prev_input));
}

pub fn isAnyJustPressed(keys: Keys) bool {
    return curr_input.differenceWith(prev_input).intersectWith(keys).eql(Keys.initEmpty());
}

pub fn isKeyJustPressed(key: Key) bool {
    return curr_input.differenceWith(prev_input).contains(key);
}

pub fn isKeyJustReleased(key: Key) bool {
    return prev_input.differenceWith(curr_input).contains(key);
}

test "Test Axis.get()" {
    curr_input = Keys.initOne(.left);
    try std.testing.expectEqual(-1, getAxis(.horizontal));
    curr_input.insert(.right);
    try std.testing.expectEqual(0, getAxis(.horizontal));
    curr_input.remove(.left);
    try std.testing.expectEqual(1, getAxis(.horizontal));
    curr_input.remove(.right);
    try std.testing.expectEqual(0, getAxis(.horizontal));
}
