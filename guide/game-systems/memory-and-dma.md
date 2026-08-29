# Memory and DMA

The important regions are EWRAM for larger data, IWRAM for smaller fast code and stack use, VRAM for graphics, palette RAM for colors, OAM for objects, and ROM for program and asset data. ZigGBA exposes these regions through `gba.mem`, but the display and sound namespaces usually provide a safer, more specific entry point.

Use ordinary copies for small or irregular work. Use DMA for larger aligned transfers when it removes real frame cost, especially copies into VRAM, palettes, or OAM. DMA has its own hardware channels and timing; do not start a transfer that conflicts with another system or assumes a destination accepts 8-bit writes.

DMA channel 3 is the general-purpose channel. The source and destination below are both 32-bit aligned, and the count is in 32-bit words rather than bytes:

```zig
const source: [256]u32 align(4) = @splat(0x001f_001f);
var destination: [256]u32 align(4) = undefined;

gba.mem.memcpyDma32(3, &destination, &source, source.len);
```

The copy is synchronous: the CPU and interrupts are paused until it finishes. Keep that cost inside the frame budget; for display data, VBlank is usually the appropriate time to make the copy.

The [memory example](https://github.com/braheezy/ziggba/blob/master/examples/memory/memory.zig) compares CPU, BIOS, and DMA copy paths. Treat its measurements as a starting point, not a universal ranking: source region, destination region, transfer size, and timing change the result. The [memory reference](/reference/gba/) documents the memory regions, copy helpers, DMA channels, and wait-state control.
