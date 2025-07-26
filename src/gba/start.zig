const gba = @import("gba");

const bios = gba.bios;
const mem = gba.mem;

/// This function is called after boot and initialization.
/// It must be defined in user code.
extern fn main() void;

extern var __bss_lma: u8;
extern var __bss_start__: u8;
extern var __bss_end__: u8;
extern var __data_lma: u8;
extern var __data_start__: u8;
extern var __data_end__: u8;
extern var __iwram_lma: u8;
extern var __iwram_start__: u8;
extern var __iwram_end__: u8;

export fn _start_zig() noreturn {
    // Use BIOS function to clear all data
    bios.resetRamRegisters(bios.RamResetFlags.initFull());
    // Clear .bss
    mem.memset32(&__bss_start__, 0, @intFromPtr(&__bss_end__) - @intFromPtr(&__bss_start__));
    // Copy .data section to EWRAM
    mem.memcpy32(&__data_start__, &__data_lma, @intFromPtr(&__data_end__) - @intFromPtr(&__data_start__));

    // Copy .iwram section (code/data to be run in IWRAM)
    if (@intFromPtr(&__iwram_end__) - @intFromPtr(&__iwram_start__) > 0) {
        mem.memcpy32(
            &__iwram_start__,
            &__iwram_lma,
            @intFromPtr(&__iwram_end__) - @intFromPtr(&__iwram_start__),
        );
    }
    // Call user's main
    main();
    // If user's main ends, hang here
    while (true) {}
}
