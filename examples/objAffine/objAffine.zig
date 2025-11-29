const gba = @import("gba");
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.Header.init("OBJAFFINE", "AOAE", "00", 0);

var affine_state: AffineState = .null;
var aff_value: i32 = 0;
// 'speeds' of transformations
const aff_diffs = [_]i32{ 0, 128, 4, 4, 4, 4 };
const aff_keys = [_]?input.Key{ null, .L, .select, .select, .right, .up };

pub export fn main() void {
    gba.display.memcpyObjectTiles4Bpp(0, @ptrCast(&metr.box_tiles));
    gba.display.memcpyObjectPalette(0, @ptrCast(&metr.pal));

    const metroid: gba.display.Object = .initAffine(.{
        .size = .size_64x64,
        .x = 96,
        .y = 32,
        .affine_index = 0,
    });
    gba.display.setObjectTransform(metroid.transform.affine_index, .identity);

    const shadow_metroid: gba.display.Object = .initAffine(.{
        .size = .size_64x64,
        .x = 96,
        .y = 32,
        .affine_index = 1,
        .palette = 1,
    });
    gba.display.setObjectTransform(shadow_metroid.transform.affine_index, .identity);

    gba.display.hideAllObjects();
    gba.display.objects[0] = metroid;
    gba.display.objects[1] = shadow_metroid;

    gba.display.ctrl.* = gba.display.Control{
        .obj_mapping = .map_1d,
        .bg0 = true,
        .obj = true,
    };

    var frame: u32 = 0;

    while (true) : (frame +%= 1) {
        gba.display.naiveVSync();

        gba.display.setObjectTransform(metroid.transform.affine_index, .initRotation(
            .initRaw(@truncate(frame << 8)),
        ));
    }
}

const AffineState = enum {
    null,
    rotate,
    scale_x,
    scale_y,
    shear_x,
    shear_y,
};

fn getAffineState() AffineState {
    return if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .L, .R })))
        .rotate
    else if (input.isKeyPressed(.A))
        .scale_x
    else if (input.isKeyPressed(.B))
        .scale_y
    else if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .left, .right })))
        .shear_x
    else if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .up, .down })))
        .shear_y
    else
        .null;
}

fn updateAffMatrixFromState(oaff_new: *obj.Affine) void {
    switch (affine_state) {
        .rotate => {
            // L rotates left, R rotates right
            oaff_new.rotate(@intCast(aff_value));
        },
        .scale_x => {
            // A scales x, +SELECT scales down
            oaff_new.scaleInv((1 << 8) - aff_value, 1 << 8);
        },
        .scale_y => {
            // B scales y, +SELECT scales down
            oaff_new.scaleInv(1 << 8, (1 << 8) - aff_value);
        },
        .shear_x => {
            // shear left and right
            oaff_new.shearX(gba.math.I8_8.fromInt(@intCast(aff_value)));
        },
        .shear_y => {
            // shear up and down
            oaff_new.shearY(gba.math.I8_8.fromInt(@intCast(aff_value)));
        },
        else => {},
    }
}

fn getAffNew(oaff_new: *obj.Affine) void {
    const diff = aff_diffs[@intFromEnum(affine_state)];
    const maybe_key = aff_keys[@intFromEnum(affine_state)];
    if (maybe_key) |key| {
        aff_value += if (input.isKeyPressed(key)) diff else -diff;
    }

    updateAffMatrixFromState(oaff_new);
}

// Local copy helper if needed by other code
pub fn affCopy(dst: *obj.Affine, src: *const obj.Affine) void {
    dst.* = src.*;
}

fn toI8_8(raw: i32) gba.math.I8_8 {
    return @bitCast(@as(i16, @truncate(raw)));
}

fn affPostMul(dst: *obj.Affine, src: *const obj.Affine) void {
    const tmp_a: i32 = dst.pa.raw();
    const tmp_b: i32 = dst.pb.raw();
    const tmp_c: i32 = dst.pc.raw();
    const tmp_d: i32 = dst.pd.raw();

    const res_pa = (tmp_a * src.pa.raw() + tmp_b * src.pc.raw()) >> 8;
    const res_pb = (tmp_a * src.pb.raw() + tmp_b * src.pd.raw()) >> 8;
    const res_pc = (tmp_c * src.pa.raw() + tmp_d * src.pc.raw()) >> 8;
    const res_pd = (tmp_c * src.pb.raw() + tmp_d * src.pd.raw()) >> 8;

    dst.pa = toI8_8(res_pa);
    dst.pb = toI8_8(res_pb);
    dst.pc = toI8_8(res_pc);
    dst.pd = toI8_8(res_pd);
}
