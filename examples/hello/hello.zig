const gba = @import("gba");

export var header linksection(".gbaheader") = gba.Header.init(
    "AHELL",
    "AHEL",
    "00",
    0,
);

export fn main() void {
    gba.display.ctrl.* = .initMode3(.{});

    const mode3 = gba.display.getMode3Surface();
    mode3.draw().text("Hello World!", .init(gba.ColorRgb555.white), .{
        .x = 72,
        .y = 64,
    });
}
