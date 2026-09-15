//! ARM-target compile coverage for every hardware save backend.
//!
//! These exports are not called by a ROM. Keeping them exported makes Zig
//! type-check and generate the backend paths, while host tests exercise the
//! media-independent record logic through a fake backend.

const gba = @import("gba");

fn exercise(comptime media: gba.save.Media) void {
    const Saves = gba.save.SlotManager(media, .{
        .slot_count = 1,
        .payload_len = 32,
    });
    var saves = Saves.init(.{ .game_id = "org.ziggba.save-target-compile" }) catch unreachable;
    var payload: [32]u8 = undefined;

    _ = saves.slotStatus(0, null) catch {};
    saves.store(0, &.{}, &payload) catch {};
    saves.load(0, &payload) catch {};
    saves.eraseSlot(0) catch {};
}

pub export fn compileSramSaveBackend() void {
    exercise(.sram);
}

pub export fn compileFlash64SaveBackend() void {
    exercise(.flash_64k);
}

pub export fn compileFlash128SaveBackend() void {
    exercise(.flash_128k);
}

pub export fn compileEeprom512SaveBackend() void {
    exercise(.eeprom_512b);
}

pub export fn compileEeprom8kSaveBackend() void {
    exercise(.eeprom_8k);
}
