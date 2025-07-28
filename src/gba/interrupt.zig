const std = @import("std");
const gba = @import("gba.zig");
const Enable = gba.utils.Enable;
const interrupt = @This();

pub const ctrl: *volatile interrupt.Control = @ptrFromInt(gba.mem.io + 0x200);
const ime: *volatile Enable = @ptrFromInt(gba.mem.io + 0x208);

pub const Flag = enum {
    vblank,
    hblank,
    timer_0,
    timer_1,
    timer_2,
    timer_3,
    serial,
    dma_0,
    dma_1,
    dma_2,
    dma_3,
    keypad,
    gamepak,
};

pub const Flags = std.EnumSet(interrupt.Flag);

pub const WaitReturn = enum(u32) {
    return_immediately,
    discard_old_wait_new,
};

// ISR table entry - similar to libtonc's IRQ_REC
pub const IsrEntry = struct {
    flag: u32, // Interrupt flag bit
    handler: ?*const fn () void, // Handler function pointer
};

// Global ISR table - similar to libtonc's __isr_table
extern var isr_table: [112]u8 align(4); // 14 entries * 8 bytes each

fn table() *[14]IsrEntry {
    return @ptrCast(&isr_table);
}

// External function implemented in assembly (src/build/isr_master.s)
pub extern fn isr_master() callconv(.C) void;

// Initialize the ISR table
pub fn init() void {
    // Clear the table
    for (table()) |*entry| {
        entry.* = .{ .flag = 0, .handler = null };
    }

    // Disable all triggers initially
    (@constCast(ctrl)).triggers_bits = 0;

    // Enable global interrupt master switch (IME)
    ime.* = .enable;
}

/// Adds or replaces an interrupt handler and enables the corresponding
/// hardware interrupt sources (similar to tonc's irq_add).
/// If `handler` is null, only the hardware interrupt is enabled.
pub fn add(flag: Flag, handler: ?*const fn () void) ?*const fn () void {
    const old = setHandler(flag, handler);

    // Enable the interrupt in IE register
    (@constCast(ctrl)).enableTrigger(flag);

    // Some sources need an extra enable in DISPSTAT
    switch (flag) {
        .vblank => {
            const dispstat: *volatile u16 = @ptrCast(gba.display.status);
            dispstat.* |= 0x0008; // bit 3: VBlank IRQ enable
        },
        .hblank => {
            const dispstat: *volatile u16 = @ptrCast(gba.display.status);
            dispstat.* |= 0x0010; // bit 4: HBlank IRQ enable
        },
        else => {},
    }
    return old;
}

// Register an interrupt handler
pub fn setHandler(flag: Flag, handler: ?*const fn () void) ?*const fn () void {
    const flag_bit = @as(u32, 1) << @intFromEnum(flag);

    // Find existing entry or empty slot
    var i: usize = 0;
    while (i < 14 - 1) : (i += 1) {
        if (table()[i].flag == flag_bit) {
            const old_handler = table()[i].handler;
            table()[i].handler = handler;
            return old_handler;
        }
        if (table()[i].flag == 0) break;
    }

    // Add new entry
    if (i < 14 - 1) {
        table()[i] = .{ .flag = flag_bit, .handler = handler };
    }

    return null;
}

pub const Control = extern struct {
    /// When `master` is enabled, the events specified by these flags will trigger an interrupt.
    /// Stored as raw bits for extern compatibility; use helper functions for safe access.
    triggers_bits: u16 align(2),
    /// Active interrupt requests can be read from this register.
    irq_ack_bits: u16 align(2),
    // No IME here; use global `ime` constant for master enable

    /// Enables an individual interrupt source in IE.
    pub fn enableTrigger(self: *volatile Control, flag: Flag) void {
        self.triggers_bits |= @as(u16, 1) << @intFromEnum(flag);
    }

    /// Writes a 1 to IF for the given flag to acknowledge it.
    pub fn acknowledge(self: *volatile Control, flag: Flag) void {
        self.irq_ack_bits = @as(u16, 1) << @intFromEnum(flag);
    }
};
