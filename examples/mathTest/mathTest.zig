const gba = vectors.gba;
const vectors = @import("gba_tests").bios_arctan2;

export var header linksection(".gbaheader") = gba.Header.init("MATHTEST", "ZATE", "00", 0);

pub export fn main() void {
    gba.display.ctrl.* = .initMode3(.{});
    var failed: usize = 0;
    for (vectors.cases) |case| {
        const actual = gba.bios.arctan2(case.x, case.y).value;
        if (!case.accepts(actual)) {
            failed += 1;
            gba.debug.print("FAIL arctan2({d},{d}): expected {x}, actual {x}, tolerance {d}", .{
                case.x, case.y, case.expected, actual, case.tolerance,
            }) catch {};
        }
    }
    gba.debug.print("ARCTAN2: {d}/{d} passed", .{ vectors.cases.len - failed, vectors.cases.len }) catch {};
    const color: gba.ColorRgb555 = if (failed == 0) .green else .red;
    const surface = gba.display.getMode3Surface();
    for (0..160) |y| {
        for (0..240) |x| surface.setPixel(@intCast(x), @intCast(y), color);
    }
    while (true) gba.display.naiveVSync();
}
