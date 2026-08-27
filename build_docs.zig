//! Build-time APIs for projects that depend on ZigGBA.
//!
//! Import the package as `ziggba` in a game's `build.zig`, then create a
//! `GbaBuild` to define ROM targets and process assets.

/// Build helpers used by a game's `build.zig` to produce GBA ROMs and assets.
pub const GbaBuild = @import("gba_build.zig").GbaBuild;

/// Color types and palette helpers available to build scripts.
pub const color = @import("build/color.zig");
