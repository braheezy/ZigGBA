# ZigGBA

ZigGBA is an SDK for creating Game Boy Advance games using the [Zig](https://ziglang.org/) programming language. It is currently in a WIP/experimental state. This repository is a maintained fork of [wendigojaeger/ZigGBA](https://github.com/wendigojaeger/ZigGBA).

Many thanks to [TONC](https://gbadev.net/tonc/) and [GBATEK](https://problemkaputt.de/gbatek.htm), both of which have been major inspirations and resources for this project.

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

This library uses Zig 0.14.1. To install using [`zigup`](https://github.com/marler8997/zigup):

```sh
zigup 0.14.1
```

To build, simply use Zig's integrated build system

```bash
zig build
```

ZigGBA's `zig build` will write example ROMs to `zig-out/bin/`. These are files with a `*.gba` extension which can be run on a GBA using special hardware, or which can run in emulators such as [mGBA](https://github.com/mgba-emu/mgba), [Mesen](https://github.com/SourMesen/Mesen2/), [no$gba](https://problemkaputt.de/gba.htm), and [NanoBoyAdvance](https://github.com/nba-emu/NanoBoyAdvance).

## Showcase

First example running on an emulator:

![First example emulator image](docs/images/FirstExampleEmulator.png)

First example running on real hardware:

![First example real hardware image](docs/images/FirstExampleRealHardware.png)
