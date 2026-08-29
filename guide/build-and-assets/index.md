# Build and asset workflow

ZigGBA can turn a PNG into the data the GBA expects while it builds the ROM. Put source images in your project, describe how each one should be converted in `build.zig`, then import the generated data from game code. Running `zig build` reruns a conversion only when its source image or options changed.

## Add an image to the build

Create the ROM target first, then create an asset module from it. This example converts `assets/player.png` into the default sprite format and makes the result available to `src/main.zig` as `@import("assets")`:

```zig
const exe = gba_b.addExecutable(.{
    .name = "game",
    .root_source_file = b.path("src/main.zig"),
});

var assets = exe.createAssetModule();
_ = assets.addImage("player", .{
    .source_file = b.path("assets/player.png"),
});
assets.addImport("assets");
```

The name passed to `addImage` becomes the field name in the generated module. Copy a sprite's tile pixels and colors into object memory before using it:

```zig
const gba = @import("gba");
const assets = @import("assets");

const player = assets.player;

gba.display.memcpyObjectTiles4Bpp(0, player.tiles[0..]);
gba.display.memcpyObjectPalette(0, player.palette[0..]);
```

That is the whole loop: edit the PNG, run `zig build`, and run the new ROM. If conversion fails, the build error identifies the image and usually the constraint it violated, such as too many colors for the selected format.

## Choose an output format

The default is `.obj_tiles_4bpp`: sprite tiles with up to fifteen visible colors plus transparent pixels. Set `format` when the image is for something else.

| Format | Use it for | Important limit |
| --- | --- | --- |
| `.obj_tiles_4bpp` | Sprites and small animated objects | Fifteen visible colors per palette bank; index zero is transparent |
| `.bg_tilemap_4bpp` | A normal tiled background with one 16-color bank | Each tile uses that shared bank |
| `.bg_tilemap_4bpp_multi_bank` | A normal tiled background with more colors overall | Each tile must still fit in one 16-color bank |
| `.bg_tilemap_8bpp` | A normal tiled background with a 256-color palette | Uses more tile memory |
| `.affine_bg_tilemap_8bpp` | A tiled background that rotates or scales | Uses affine-background rules |
| `.mode4_bitmap_8bpp` | Full-screen indexed artwork in Mode 4 | One 256-color palette shared by the screen |

For example, a level image can become a tiled Mode 0 background:

```zig
_ = assets.addImage("level", .{
    .source_file = b.path("assets/level.png"),
    .format = .bg_tilemap_4bpp,
    .tilemap = .{
        .dedupe = true,
        .dedupe_flips = true,
    },
});
```

This generates `level.tiles`, `level.palette`, and `level.map`. [Backgrounds and tile maps](../graphics/backgrounds.md) shows where those three pieces go at runtime.

## Options worth knowing

Use `sprite_sheet` when one image contains animation frames. Provide `frame_width` and `frame_height`; the generated asset exposes frame counts and tile positions. Use a provided palette when several images must share exactly the same colors. `dedupe` removes identical tiles, while `dedupe_flips` also reuses a horizontally or vertically flipped tile; both reduce ROM and VRAM use but make the generated tile order less direct to inspect.

LZ77 compression is available per generated output—tiles, maps, pixels, or palettes. Add it only when ROM size is a real concern, because compressed data must be unpacked before use. The [build API reference](/reference/build/) lists the exact options and generated field names; the [runtime API reference](/reference/gba/) covers the display-memory copy helpers.
