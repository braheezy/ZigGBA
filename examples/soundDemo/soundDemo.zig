const gba = @import("gba");
const Color = gba.Color;
const input = gba.input;
const display = gba.display;
const text = gba.text;
const math = gba.math;
const interrupt = gba.interrupt;
const bg = gba.bg;
const bios = gba.bios;

const std = @import("std");

export const gameHeader linksection(".gbaheader") = gba.initHeader("SND1", "ASTE", "00", 0);

var dir = input.Combo.dir;

var text_scroll_y: i16 = 8;

const names = [_][]const u8{
    "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B ",
};

// Play a note and show which one was played
fn notePlay(note: i32, octave: i32) void {
    const row: u5 = @intCast((text_scroll_y >> 3) & 0x1F);
    gba.bg.screenBlockClearRow(31, (row - 2));
    gba.bg.screenBlockClearRow(31, row);

    // Display note and scroll
    const note_index: usize = @intCast(note);
    text.printf(
        "#{{P:16,{d};cx:0}}{s:<2}{d:<2}",
        .{ text_scroll_y, names[note_index], octave },
    );

    text_scroll_y -= 8;
    gba.bg.scroll[0].set(0, @intCast(text_scroll_y - 8));

    // Play the actual note
    gba.sound.pulse_1_freq.* = rate(note, octave);
}

// Show the octave the next note will be in
fn notePrep(octave: i32) void {
    text.printf("#{{P:8,{d};cx:0x1000}}[  {d:>2}]", .{ text_scroll_y, octave });
}

fn rate(note: i32, octave: i32) gba.sound.PulseChannelFrequency {
    const n: usize = @intCast(note);
    return .{
        .rate = @intCast(2048 - (gba.sound.rates[n] >> @as(u4, @intCast(4 + octave)))),
        .reset = true,
    };
}

// Play a little ditty
fn sos() void {
    const lens = [_]u8{ 1, 1, 4, 1, 1, 4 };
    const notes = [_]u8{ 0x02, 0x05, 0x12, 0x02, 0x05, 0x12 };
    var ii: usize = 0;
    while (ii < 6) : (ii += 1) {
        notePlay(notes[ii] & 15, notes[ii] >> 4);
        bios.vBlankIntrDelay(8 * lens[ii]);
    }
}

pub export fn main() void {
    display.ctrl.* = display.Control{
        .bg0 = .enable,
        .mode = .mode0,
    };

    interrupt.init();
    _ = interrupt.add(.vblank, null);

    gba.text.initSe(
        0,
        .{
            .tile_base_block = 0,
            .screen_base_block = 31,
        },
        Color.orange,
    );

    bg.palette.full[0x11] = @bitCast(Color.green);

    gba.sound.status.* = gba.sound.Status{
        .master = .enable,
    };
    gba.sound.dmg.* = gba.sound.Dmg{
        .left_volume = 0x7,
        .right_volume = 0x7,
        .left_pulse_1 = .enable,
        .right_pulse_1 = .enable,
    };
    gba.sound.dsound.* = gba.sound.DirectSound{
        .volume_dmg = .percent_100,
    };
    gba.sound.pulse_1_sweep.* = .{};
    gba.sound.pulse_1_ctrl.* = gba.sound.PulseChannelControl{
        .volume = 12,
        .step = 7,
        .duty = .hi_1_lo_1,
    };
    gba.sound.pulse_1_freq.* = gba.sound.ChannelFrequency{};

    sos();

    var octave: i32 = 0;
    dir.insert(.A);

    while (true) {
        display.vSync();
        _ = input.poll();

        // change octave
        octave += input.getAxisJustChanged(.shoulders).toInt();
        octave = std.math.clamp(octave, -2, 6);
        notePrep(octave);

        // play note
        if (input.isKeyJustPressed(.up)) {
            notePlay(@intFromEnum(gba.sound.Note.D), octave + 1);
        } else if (input.isKeyJustPressed(.left)) {
            notePlay(@intFromEnum(gba.sound.Note.B), octave);
        } else if (input.isKeyJustPressed(.right)) {
            notePlay(@intFromEnum(gba.sound.Note.A), octave);
        } else if (input.isKeyJustPressed(.down)) {
            notePlay(@intFromEnum(gba.sound.Note.F), octave);
        } else if (input.isKeyJustPressed(.A)) {
            notePlay(@intFromEnum(gba.sound.Note.D), octave);
        }

        // play ditty
        if (input.isKeyJustPressed(.B)) sos();
    }
}
