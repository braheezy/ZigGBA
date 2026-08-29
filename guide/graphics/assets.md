# Image assets

Use `createAssetModule` for ordinary game art. It turns source images into a Zig module, so game code imports typed asset data instead of opening generated binary files by name.

```zig
var assets = exe.createAssetModule();
_ = assets.addImage("player", .{
    .source_file = b.path("assets/player.png"),
});
assets.addImport("assets");
```

The default target is a 4bpp OBJ tile asset. It reserves palette index zero for transparency and rejects more than fifteen opaque colors. Choose an explicit image format when you need a tile map, a Mode 4 bitmap, an 8bpp background, or multiple 4bpp palette banks.

Generated assets expose the data that the runtime expects, such as `tiles`, `palette`, `map`, frame metadata, and compressed variants. Copy those into the matching display memory. The [build reference](/reference/build/) documents formats and options; the [display reference](/reference/gba/) documents the copy functions.
