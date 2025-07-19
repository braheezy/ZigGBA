const gba = @import("gba");
const input = gba.input;
const display = gba.display;
const obj = gba.obj;
const debug = gba.debug;
const math = gba.math;
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.initHeader("OBJAFFINE", "AODE", "00", 0);

var affine_state: AffineState = .null;
var aff_value: i32 = 0;
// 'speeds' of transformations
const aff_diffs = [_]i32{ 0, 128, 4, 4, 4, 4 };
const aff_keys = [_]?input.Key{ null, .L, .select, .select, .right, .up };

export fn main() void {
    display.ctrl.* = .{
        .obj_mapping = .one_dimension,
        .bg0 = .enable,
        .obj = .enable,
    };

    debug.init();

    gba.mem.memcpy32(obj.tile_ram, &metr.box_tiles, metr.box_tiles.len * 4);
    gba.mem.memcpy32(obj.palette, &metr.pal, metr.pal.len * 4);

    gba.text.initChr4cDefault(0, .{
        .tile_base_block = 2,
        .screen_base_block = 28,
    });

    // Set text margins equivalent to tonc's tte_set_margins(8, 128, 232, 160).
    gba.text.setMargins(8, 128, 232, 160);

    var x: i9 = 96;
    var y: i8 = 32;

    const metroid = obj.allocate();
    metroid.* = .{
        .affine_mode = .affine,
        .transform = .{ .affine_index = 0 },
    };
    metroid.setSize(.@"64x64");
    metroid.setPosition(@bitCast(x), @bitCast(y));
    metroid.getAffine().setIdentity();

    const shadow_metroid = obj.allocate();
    shadow_metroid.* = .{
        .affine_mode = .affine,
        .transform = .{ .affine_index = 31 }, // Use different affine index to match tonc
        .palette = 1,
    };
    shadow_metroid.setSize(.@"64x64");
    shadow_metroid.setPosition(@bitCast(x), @bitCast(y));
    shadow_metroid.getAffine().setIdentity(); // This matrix is never touched again

    const fmt = "#{{P:8,136}}P = | {X:0>4}\t{X:0>4} |\n    | {X:0>4}\t{X:0>4} |";
    var new_state: AffineState = .null;
    // Get references to the affine matrices for the sprites
    var oaff_curr = metroid.getAffine();
    var oaff_base = &obj.obj_affine_buffer.affine[1]; // Use buffer slot 1 for base
    var oaff_new = &obj.obj_affine_buffer.affine[2]; // Use buffer slot 2 for new

    oaff_curr.setIdentity();
    oaff_base.setIdentity();
    oaff_new.setIdentity();

    // Initial copy of all affine matrices to OAM (like tonc's oam_copy)
    obj.updateAffine(32);

    while (true) {
        _ = input.poll();

        // move sprite around
        if (input.isKeyPressed(.select) and input.isAnyPressed(input.Combo.dir)) {
            x += 2 * @as(i9, @intCast(input.getAxis(.horizontal).toInt()));
            y += 2 * @as(i8, @intCast(input.getAxis(.vertical).toInt()));

            metroid.setPosition(@bitCast(x), @bitCast(y));
            shadow_metroid.setPosition(@bitCast(x), @bitCast(y));
            new_state = .null;
        } else {
            // do affine transformation
            new_state = getAffineState();
        }

        if (new_state != .null) {
            if (new_state == affine_state) {
                getAffNew(oaff_new);
                // oaff_curr = oaff_base * oaff_new
                oaff_curr.* = oaff_base.*;
                affPostMul(oaff_curr, oaff_new);
            } else {
                // switch to different transformation type
                oaff_base.* = oaff_curr.*;
                oaff_new.setIdentity();
                aff_value = 0;
            }
            affine_state = new_state;
        }

        // START: toggles double-size flag
        // START+SELECT: resets obj_aff to identity
        if (input.isKeyJustPressed(.start)) {
            if (input.isKeyPressed(.select)) {
                oaff_curr.setIdentity();
                oaff_base.setIdentity();
                oaff_new.setIdentity();
                aff_value = 0;
            } else {
                // Toggle double-size flag (equivalent to tonc's ^= ATTR0_AFF_DBL_BIT)
                if (metroid.affine_mode == .affine) {
                    metroid.affine_mode = .affine_double;
                } else if (metroid.affine_mode == .affine_double) {
                    metroid.affine_mode = .affine;
                }
                if (shadow_metroid.affine_mode == .affine) {
                    shadow_metroid.affine_mode = .affine_double;
                } else if (shadow_metroid.affine_mode == .affine_double) {
                    shadow_metroid.affine_mode = .affine;
                }
            }
        }

        display.naiveVSync();

        obj.update(2);
        obj.updateAffine(3);

        gba.text.printf(fmt, .{
            @as(u16, @bitCast(oaff_curr.pa.raw())),
            @as(u16, @bitCast(oaff_curr.pb.raw())),
            @as(u16, @bitCast(oaff_curr.pc.raw())),
            @as(u16, @bitCast(oaff_curr.pd.raw())),
        });
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
