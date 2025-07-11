# Zig GBA

This is a work in progress SDK for creating Game Boy Advance games using the [Zig](https://ziglang.org/) programming language. Once Zig has a proper package manager, I hope that it would as easy as import the ZigGBA package. Inspired by [TONC GBA tutorial](https://gbadev.net/tonc/)

## Setup

Add to your `build.zig.zon`:

    zig fetch --save git+https://github.com/braheezy/ZigGBA.git

If you want to use the build helper for converting assets (most users do), add `zigimg`:

    zig fetch --save git+https://github.com/zigimg/zigimg.git

In your `build.zig`:

```zig
const std = @import("std");
// Import ziggba to get access to build helpers
const ziggba = @import("ziggba");

pub fn build(b: *std.Build) void {
    // Get the GBA module
    const ziggba_dep = b.dependency("ziggba", .{});
    const gba_mod = ziggba_dep.module("gba");

    // Using a build helper, build a GBA ROM from your source
    _ = ziggba.addGBAExecutable(b, gba_mod, "tonc_tutor", "src/main.zig");

    const mode4flip = ziggba.addGBAExecutable(b, gba_mod, "mode4flip", "mode4flip.zig");
    // Convert bitmaps and create a palette. This requires `zigimg` in your `build.zig.zon`
    ziggba.convertMode4Images(mode4flip, &[_]ziggba.ImageSourceTarget{
        .{
            .source = "front.bmp",
            .target = "front.agi",
        },
        .{
            .source = "back.bmp",
            .target = "back.agi",
        },
    }, "mode4flip.agp");
}

```

## Build

This library uses zig nominated [2024.10.0-mach](https://machengine.org/about/nominated-zig/). To install using [`zigup`](https://github.com/marler8997/zigup):

```sh
zigup 0.14.0-dev.1911+3bf89f55c
```

To build, simply use Zig's integrated build system

```bash
zig build
```

## First example running in a emulator

![First example emulator image](docs/images/FirstExampleEmulator.png)

## First example running on real hardware

![First example real hardware image](docs/images/FirstExampleRealHardware.png)
