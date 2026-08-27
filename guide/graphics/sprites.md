# Sprites and objects

Sprites use the GBA's object, or OBJ, hardware. An object entry selects a shape, size, position, tile index, palette bank, and optional affine transform. The hardware owns 128 entries, so reserve ranges deliberately when several systems create objects.

Set `display.ctrl.obj` and choose an object tile mapping mode before writing object entries. In one-dimensional mapping, a sprite's tiles are laid out linearly; it is often easier to reason about for generated sprite sheets. Copy object tiles and an object palette, then assign a `gba.display.Object` to an element of `gba.display.objects`.

```zig
var player: gba.display.Object = .init(.{
    .size = .size_32x32,
    .x = 96,
    .y = 64,
});
player.base_tile = 0;
gba.display.objects[0] = player;
```

The object demo shows movement, palette selection, and flips. For range checks, affine transforms, and the packed attribute fields, use the [display reference](/reference/gba/).
