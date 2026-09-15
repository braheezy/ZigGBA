# Save data

`gba.save` manages a small number of fixed-size, byte-oriented save slots. Every slot has a second on-cartridge record reserved for recovery: a new save is written and checked before it becomes current, so an interrupted write leaves the previous complete save available.

Choose the cartridge medium before designing the save layout. SRAM is the usual choice for a new project because it is simple and has 32 KiB of portable capacity. Flash is useful when a cartridge requires it, while EEPROM is best reserved for layouts that truly fit its much smaller space.

| Media | Usable capacity | Notes |
| --- | ---: | --- |
| `.sram` | 32 KiB | Fast, byte-addressable, and the recommended default |
| `.flash_64k` | 64 KiB | Erases sectors before writing; stores block the game |
| `.flash_128k` | 128 KiB | The two-bank Flash variant |
| `.eeprom_512b` | 512 bytes | Only practical for very small records |
| `.eeprom_8k` | 8 KiB | Uses DMA channel 3 while transferring blocks |

The selected medium must match the cartridge or flash-cart setting. Export its conventional ROM marker as well, so mGBA and compatible tooling choose the same save type:

```zig
export var save_media_marker linksection(".gba_save_marker") = gba.save.romMarker(.sram);
```

The marker does not add hardware to a cartridge. Use the [runtime API reference](/reference/gba/) for the exact media types and backend behavior.

## Define the slot layout

The manager knows byte counts, not Zig structs. That keeps the on-cartridge format stable when a struct gains padding or a field changes. Put explicit encoding and decoding next to the game state they describe.

```zig
const gba = @import("gba");

const Saves = gba.save.SlotManager(.sram, .{
    .slot_count = 3,
    .summary_len = 8,
    .payload_len = 64,
});

var saves = try Saves.init(.{
    .game_id = "com.example.starscout",
    .format_version = 1,
});
```

`game_id` distinguishes one game's records from another. Keep it stable. Increase `format_version` only when the payload changes incompatibly; older records will then report as `.incompatible` rather than being decoded incorrectly.

`summary_len` is optional metadata for a save-select screen. A slot with no summary omits the field, as in `summary_len = 0`; pass `&.{}` to `store` in that case. `payload_len` is the exact encoded size of one game state.

## Load and save

Check the status before loading. The output buffers must exactly match the configured lengths, and no allocation occurs.

```zig
var summary: [8]u8 = undefined;
var payload: [64]u8 = undefined;

switch (try saves.slotStatus(0, &summary)) {
    .valid => try saves.load(0, &payload),
    .empty => {}, // Offer a new game.
    .corrupt => {}, // Tell the player the slot cannot be read.
    .incompatible => {}, // Offer migration or a fresh slot.
}

// Fill both arrays with the game's explicit encoded data first.
try saves.store(0, &summary, &payload);
```

`store` writes the inactive record, checks its CRCs, and commits it last. It does not silently repair a damaged slot. `eraseSlot(0)` uses the same recovery path to make a slot empty.

The [save example](https://github.com/braheezy/ziggba/tree/master/examples/save) persists a counter with three slots. Its counter encoder is deliberately ordinary byte code; using raw in-memory bytes from an arbitrary struct makes a save format fragile across field, padding, and pointer changes.

## Plan capacity and write time

Each logical slot consumes two records. A record is a 48-byte header plus its summary and payload, rounded up to the media erase/block alignment. Call `Saves.capacity()` while choosing the layout to inspect the record size, total reservation, and unused medium capacity.

Saving SRAM is synchronous and usually short, but keep it at a deliberate point in the frame. Flash erases and writes synchronously and can visibly pause a game; EEPROM also blocks and reserves DMA3 for the transfer. Do not start another DMA3 job while an EEPROM save is active.

`zig build save-bench` produces an SRAM ROM that logs minimum, median, and maximum cycle counts for a slot scan, 512-byte load, and 512-byte store. Use it to compare the emulator and hardware you actually ship on, rather than treating one machine's numbers as a universal budget.

## Hardware validation

The record format, recovery path, and SRAM workflow are covered by host fault-injection tests. The Flash and EEPROM implementations use the same record layer but need target-specific validation before a game relies on them: test the selected capacity in mGBA, the intended flash cart, and real cartridge hardware where applicable. In particular, check Flash save timing alongside audio and frame pacing.
