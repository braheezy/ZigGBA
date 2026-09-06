const gba = @import("gba");

export var header linksection(".gbaheader") = gba.Header.init("SAVEDEMO", "ZSAE", "00", 0);
// This marker lets mGBA and compatible tooling configure SRAM for this ROM.
export var save_media_marker linksection(".gba_save_marker") = gba.save.romMarker(.sram);

const Saves = gba.save.SlotManager(.sram, .{
    .slot_count = 3,
    .summary_len = 4,
    .payload_len = 32,
});

fn encodeCounter(counter: u32, bytes: *[32]u8) void {
    bytes.* = @splat(0);
    bytes[0] = @truncate(counter);
    bytes[1] = @truncate(counter >> 8);
    bytes[2] = @truncate(counter >> 16);
    bytes[3] = @truncate(counter >> 24);
}

fn decodeCounter(bytes: *const [32]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn drawStatus(color: gba.ColorRgb555) void {
    const surface = gba.display.getMode3Surface();
    for (72..168) |x| {
        for (52..108) |y| surface.setPixel(@intCast(x), @intCast(y), color);
    }
}

pub export fn main() void {
    gba.display.ctrl.* = .initMode3(.{});
    gba.debug.init();

    var saves = Saves.init(.{ .game_id = "org.ziggba.save-demo" }) catch unreachable;
    var summary: [4]u8 = undefined;
    var payload: [32]u8 = undefined;
    var counter: u32 = 0;

    switch (saves.slotStatus(0, &summary) catch .corrupt) {
        .valid => {
            saves.load(0, &payload) catch unreachable;
            counter = decodeCounter(&payload);
            drawStatus(.green);
            gba.debug.print("Loaded save {d}", .{counter}) catch {};
        },
        .empty => {
            encodeCounter(counter, &payload);
            summary = .{ 0, 0, 0, 0 };
            saves.store(0, &summary, &payload) catch unreachable;
            drawStatus(.blue);
            gba.debug.write("Created save 0");
        },
        .corrupt, .incompatible => {
            drawStatus(.red);
            gba.debug.write("Save 0 needs player recovery");
        },
    }

    var input: gba.input.BufferedKeysState = .{};
    while (true) {
        gba.display.naiveVSync();
        input.poll();

        if (input.isJustPressed(.A)) {
            counter +%= 1;
            encodeCounter(counter, &payload);
            summary = .{ @truncate(counter), @truncate(counter >> 8), 0, 0 };
            if (saves.store(0, &summary, &payload)) |_| {
                drawStatus(.green);
                gba.debug.print("Stored save {d}", .{counter}) catch {};
            } else |_| {
                drawStatus(.red);
                gba.debug.write("Save write failed");
            }
        }
        if (input.isJustPressed(.B)) {
            if (saves.eraseSlot(0)) |_| {
                drawStatus(.blue);
                gba.debug.write("Erased save 0");
            } else |_| {
                drawStatus(.red);
                gba.debug.write("Save erase failed");
            }
        }
    }
}
