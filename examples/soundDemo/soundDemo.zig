const gba = @import("gba");
const Color = gba.ColorRgb555;
const display = gba.display;
const bios = gba.bios;

const std = @import("std");

export const gameHeader linksection(".gbaheader") = gba.Header.init(
    "ASND1",
    "ASTE",
    "00",
    0,
);

const names = [_][]const u8{
    "C ", "C#", "D ", "D#", "E ", "F ", "F#", "G ", "G#", "A ", "A#", "B ",
};

const text_surface = gba.display.bg_blocks.getSurface4Bpp(0, 32, 32);
const row_height: u16 = 12;
const text_color: u4 = 1;
const accent_color: u4 = 2;
const x_note: u16 = 16;
const x_octave: u16 = 56;
const max_rows: usize = (text_surface.getHeight() / row_height) - 1; // reserve top row for preview
const NoteLine = struct { note: u8 = 0, octave: i8 = 0, valid: bool = false };
var lines: [max_rows]NoteLine = [_]NoteLine{.{}} ** max_rows;
var line_count: usize = 0;
var show_preview: bool = true;

fn clearAllRows() void {
    text_surface.fillRect(0, 0, text_surface.getWidth(), text_surface.getHeight(), 0);
}

fn redraw(octave: i32) void {
    clearAllRows();

    // Preview at row 0
    if (show_preview) {
        const sign: u8 = if (octave >= 0) '+' else '-';
        const mag: i32 = if (octave >= 0) octave else -octave;
        var prev_buf: [16]u8 = undefined;
        const prev_printed = std.fmt.bufPrint(&prev_buf, "[  {c}{d}  ]", .{ sign, mag }) catch unreachable;
        text_surface.draw().text(prev_printed, .init(accent_color), .{
            .x = 8,
            .y = 0,
            .line_height = row_height,
            .space_width = 6,
            .pad_character_width = 6,
        });
    }

    // Notes from row 1 downward.
    var y: u16 = row_height;
    var i: usize = 0;
    while (i < line_count and y + row_height <= text_surface.getHeight()) : (i += 1) {
        const line = lines[i];
        if (!line.valid) break;

        var note_buf: [4]u8 = undefined;
        const note_printed = std.fmt.bufPrint(&note_buf, "{s}", .{names[line.note]}) catch unreachable;
        text_surface.draw().text(note_printed, .init(text_color), .{
            .x = x_note,
            .y = y,
            .line_height = row_height,
            .space_width = 6,
            .pad_character_width = 6,
        });

        const sign: u8 = if (line.octave >= 0) '+' else '-';
        const mag: i32 = if (line.octave >= 0) line.octave else -line.octave;
        var oct_buf: [4]u8 = undefined;
        const oct_printed = std.fmt.bufPrint(&oct_buf, "{c}{d}", .{ sign, mag }) catch unreachable;
        text_surface.draw().text(oct_printed, .init(text_color), .{
            .x = x_octave,
            .y = y,
            .line_height = row_height,
            .space_width = 6,
            .pad_character_width = 6,
        });
        y += row_height;
    }
}

// Play a note and show which one was played
fn notePlay(note: i32, octave: i32) void {
    const note_index: usize = @intCast(note);

    // Shift stored lines down and insert new at top.
    if (line_count < max_rows) line_count += 1;
    var i: usize = line_count - 1;
    while (i > 0) : (i -= 1) {
        lines[i] = lines[i - 1];
    }
    lines[0] = .{
        .note = @intCast(note_index),
        .octave = @intCast(octave),
        .valid = true,
    };

    redraw(octave);

    // Play the actual note
    gba.sound.pulse_1_freq.* = rate(note, octave);
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
    const prev_show = show_preview;
    show_preview = false;
    const lens = [_]u8{ 1, 1, 4, 1, 1, 4 };
    const notes = [_]u8{ 0x02, 0x05, 0x12, 0x02, 0x05, 0x12 };
    var ii: usize = 0;
    while (ii < 6) : (ii += 1) {
        notePlay(notes[ii] & 15, notes[ii] >> 4);
        vBlankIntrDelay(8 * lens[ii]);
    }
    show_preview = prev_show;
}

fn vBlankIntrDelay(count: u32) void {
    for (0..count) |_| {
        bios.vblankIntrWait();
    }
}

pub export fn main() void {
    gba.display.ctrl.* = .initMode0(.{
        .bg0 = true,
    });

    gba.interrupt.master.enable = true;
    gba.interrupt.enable.vblank = true;
    gba.display.status.vblank_interrupt = true;

    const text_bg = gba.display.BackgroundMap.setup(0, .{
        .base_screenblock = 31,
    });
    text_bg.getBaseScreenblock().fillLinear(.{});
    gba.display.bg_palette.banks[0][0] = Color.black;
    gba.display.bg_palette.banks[0][text_color] = Color.rgb(31, 15, 0); // orange
    gba.display.bg_palette.banks[0][accent_color] = Color.green;
    text_surface.fillRect(0, 0, text_surface.getWidth(), text_surface.getHeight(), 0);
    gba.display.bg_scroll[0] = .{ .x = 0, .y = 0 };

    gba.sound.status.* = gba.sound.Status.init(true);
    gba.sound.ctrl.dmg = gba.sound.Control.Dmg.init(
        0x7,
        0x7,
        .{ .pulse_1 = true },
        .{ .pulse_1 = true },
    );

    gba.sound.ctrl.dsound = gba.sound.Control.DirectSound{
        .volume_dmg = .percent_100,
    };
    gba.sound.pulse_1_sweep.* = .{};
    gba.sound.pulse_1_ctrl.* = gba.sound.PulseChannelControl{
        .volume = 12,
        .step = 7,
        .duty = .hi_1_lo_1,
    };
    gba.sound.pulse_1_freq.* = gba.sound.PulseChannelFrequency{};

    var octave: i32 = 0;
    show_preview = false;
    sos();
    show_preview = true;
    redraw(octave);

    var input: gba.input.BufferedKeysState = .{};

    while (true) {
        gba.bios.vblankIntrWait();
        input.poll();

        // change octave
        octave += input.getAxisShoulders();
        octave = std.math.clamp(octave, -2, 6);

        // play note
        if (input.isJustPressed(.up)) {
            notePlay(@intFromEnum(gba.sound.Note.D), octave + 1);
        } else if (input.isJustPressed(.left)) {
            notePlay(@intFromEnum(gba.sound.Note.B), octave);
        } else if (input.isJustPressed(.right)) {
            notePlay(@intFromEnum(gba.sound.Note.A), octave);
        } else if (input.isJustPressed(.down)) {
            notePlay(@intFromEnum(gba.sound.Note.F), octave);
        } else if (input.isJustPressed(.A)) {
            notePlay(@intFromEnum(gba.sound.Note.D), octave);
        }

        // play ditty
        if (input.isJustPressed(.B)) sos();

        // Show the octave on the next line to be written.
        redraw(octave);
    }
}
