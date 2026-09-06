//! Runtime APIs for Game Boy Advance ROMs built with ZigGBA.
//!
//! Import this module as `gba`. Its namespaces group hardware access and
//! higher-level helpers; most register-backed values are `volatile` pointers
//! and should be used with the timing restrictions documented by Nintendo.

const gba = @This();

/// BIOS software interrupt routines for math, memory, decompression, and sound.
pub const bios = @import("bios/mod.zig");
/// A 15-bit RGB color stored in the GBA's native BGR555-compatible layout.
pub const ColorRgb555 = @import("graphics/color.zig").ColorRgb555;
/// Debug logging and panic helpers for supported emulators.
pub const debug = @import("debug/mod.zig");
/// Display registers, video memory, palettes, backgrounds, and sprites.
pub const display = @import("display/mod.zig");
/// Allocation-free integer formatting helpers.
pub const format = @import("format.zig");
/// The standard GBA ROM header, including a checksum-producing initializer.
pub const Header = @import("header.zig").Header;
/// Bitmap image types and drawing helpers.
pub const image = @import("graphics/image.zig");
/// Keypad input types and buffered input polling.
pub const input = @import("input.zig");
/// Interrupt configuration, flags, and handlers.
pub const interrupt = @import("interrupt.zig");
/// Fixed-point arithmetic, vectors, matrices, and affine transforms.
pub const math = @import("math/mod.zig");
/// Memory regions, DMA helpers, allocators, and wait-state control.
pub const mem = @import("memory/mod.zig");
/// Direct sound hardware registers and sound-channel definitions.
pub const sound = @import("sound.zig");
/// Optional high-level Maxmod music and sound-effect playback.
pub const audio = @import("audio.zig");
/// Reliable save slots for SRAM, Flash, and EEPROM cartridge media.
pub const save = @import("save/root.zig");
/// Bitmap-font text layout and rendering helpers.
pub const text = @import("text/mod.zig");
/// One of the GBA's hardware timers.
pub const Timer = @import("timer.zig").Timer;
/// The four memory-mapped hardware timers.
pub const timers = @import("timer.zig").timers;
