# Input

`KeysState` tells you which buttons are currently held. `BufferedKeysState` also remembers the result of the previous poll, so it can distinguish a held button from one that was just pressed or released. Use it when that distinction matters.

Poll once per frame. Repeated polling inside the same frame turns a single physical press into an inconsistent number of game updates.

```zig
var input: gba.input.BufferedKeysState = .{};

while (true) {
    gba.display.naiveVSync();
    input.poll();

    if (input.isJustPressed(.A)) {
        // Start an action once.
    }
    if (input.isPressed(.right)) {
        // Continue movement while held.
    }
}
```

`getAxisHorizontal` and `getAxisVertical` are convenient for menu cursors and simple movement. The [key demo](https://github.com/braheezy/ziggba/blob/master/examples/keydemo/keydemo.zig) uses `isJustPressed` and `isJustReleased` to color each button according to its state. See the [input reference](/reference/gba/) for all keys and interrupt-related input support.
