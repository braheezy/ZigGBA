const gba = @import("gba");

export var header linksection(".gbaheader") = gba.Header.init("MODE3DRAW", "AM3E", "00", 0);

pub export fn main() void {
    // Initialize graphics mode 3.
    gba.display.ctrl.* = .initMode3(.{});
    const surface = gba.display.getMode3Surface();
    gba.debug.init();
    const mode3 = surface.draw();

    // Fill the buffer initially with gray.
    mode3.fill(.rgb(12, 12, 12));
    
    // Draw solid rectangles.
    mode3.fillRect(12, 8, 96, 64, .red);
    mode3.fillRect(108, 72, 24, 16, .green);
    mode3.fillRect(132, 88, 96, 64, .blue);

    // Draw rectangle frames.
    mode3.rectOutline(132, 8, 96, 64, .cyan);
    mode3.rectOutline(109, 73, 22, 14, .black);
    mode3.rectOutline(12, 88, 96, 64, .yellow);
    
    // Draw lines.
    for(0..9) |i| {
        const m: u8 = @intCast(i);
        const n: u5 = @intCast(3 * m + 7);
        // Draw lines in the top right frame.
        mode3.line(
            132 + 11 * m,
            9,
            226,
            12 + 7 * m,
            .rgb(n, 0, n),
        );
        mode3.line(
            226 - 11 * m,
            70,
            133,
            69 - 7 * m,
            .rgb(n, 0, n),
        );
        // Draw lines in the bottom left frame.
        mode3.line(
            15 + 11 * m,
            88,
            104 - 11 * m,
            150,
            .rgb(0, n, n),
        );
    }
    const Check = struct {
        x: u32,
        y: u32,
        expected: gba.ColorRgb555,
        label: []const u8,
    };
    const checks = [_]Check{
        .{ .x = 0, .y = 0, .expected = .rgb(12, 12, 12), .label = "bg\n" },
        .{ .x = 12, .y = 8, .expected = .red, .label = "red\n" },
        .{ .x = 108, .y = 72, .expected = .green, .label = "green\n" },
        .{ .x = 132, .y = 88, .expected = .blue, .label = "blue\n" },
        .{ .x = 132, .y = 9, .expected = .rgb(7, 0, 7), .label = "line_tr1\n" },
        .{ .x = 226, .y = 12, .expected = .rgb(7, 0, 7), .label = "line_tr2\n" },
        .{ .x = 15, .y = 88, .expected = .rgb(0, 7, 7), .label = "line_bl1\n" },
        .{ .x = 104, .y = 150, .expected = .rgb(0, 7, 7), .label = "line_bl2\n" },
    };
    for (checks) |check| {
        const actual_bits: u16 = @bitCast(surface.getPixel(check.x, check.y));
        const expected_bits: u16 = @bitCast(check.expected);
        if (actual_bits != expected_bits) {
            gba.debug.write(check.label);
        }
    }

    // Enable VBlank interrupts.
    // This will allow running the main loop once per frame.
    gba.display.status.vblank_interrupt = true;
    gba.interrupt.enable.vblank = true;
    gba.interrupt.master.enable = true;
    
    while(true) {
        gba.bios.vblankIntrWait();
    }
}
