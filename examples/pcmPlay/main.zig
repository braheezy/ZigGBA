const gba = @import("gba");

export var header linksection(".gbaheader") = gba.initHeader("PCMDEMO", "PCMD", "00", 0);

// External PCM asset (u8 mono @ 11025 Hz). Generate via gen_audio.py in this folder.
const SAMPLE_RATE: u32 = 11_025;
const pcm_data = @embedFile("arpeggio_sine_u8_11025.pcm");
const Mode3 = @import("gba").bitmap.Mode3;

pub export fn main() void {
    // Master on and show a background color
    gba.sound.status.* = .{ .master = .enable };
    gba.display.ctrl.* = .{ .mode = .mode3, .bg2 = .enable };
    Mode3.fill(@bitCast(gba.Color.black));

    // DirectSound A: 100% volume to L+R, Timer0; pulse reset
    gba.sound.dsound.* = .{ .volume_a = .percent_100, .left_a = .enable, .right_a = .enable, .timer_a = 0, .reset_a = true };
    gba.sound.dsound.* = .{ .volume_a = .percent_100, .left_a = .enable, .right_a = .enable, .timer_a = 0, .reset_a = false };

    // Bias mid-level, 32.768 kHz
    gba.sound.bias.* = .{ .level = 0x100, .cycle = .bits_9 };

    // Timer0 at SAMPLE_RATE
    const reload: u16 = @intCast(@as(u32, 65536) - @as(u32, 16_777_216 / SAMPLE_RATE));
    gba.timer.timers[0] = gba.timer.Timer{ .counter = reload, .ctrl = .{ .freq = .cycles_1, .mode = .freq, .enable = .enable } };

    const fifo_a_u32: *volatile u32 = @ptrFromInt(gba.mem.io + 0x00A0);
    // Prime FIFO generously to ensure DS-A starts clocking
    fifo_a_u32.* = 0x80808080;
    fifo_a_u32.* = 0x80808080;
    fifo_a_u32.* = 0x80808080;
    fifo_a_u32.* = 0x80808080;

    // Timer2 as free-running counter (CPU cycles) to pace 32-bit writes
    gba.timer.timers[2] = gba.timer.Timer{ .counter = 0, .ctrl = .{ .freq = .cycles_1, .mode = .freq, .enable = .enable } };
    const writes_per_sec: u32 = SAMPLE_RATE / 4; // 4 samples per 32-bit word
    const cycles_between_writes: u16 = @intCast(16_777_216 / writes_per_sec);

    var last: u16 = gba.timer.timers[2].counter;
    var idx: usize = 0;
    var prev_note: usize = ~@as(usize, 0);
    // Small settle delay after Timer0 start
    var settle: u32 = 20000;
    while (settle > 0) : (settle -= 1) {}
    // Re-prime once more right before streaming
    fifo_a_u32.* = 0x80808080;

    while (true) {
        const now: u16 = gba.timer.timers[2].counter;
        if (now - last >= cycles_between_writes) {
            last = now;
            // Pack 4 bytes (wrap around buffer as needed)
            const s0: u8 = pcm_data[(idx + 0) % pcm_data.len];
            const s1: u8 = pcm_data[(idx + 1) % pcm_data.len];
            const s2: u8 = pcm_data[(idx + 2) % pcm_data.len];
            const s3: u8 = pcm_data[(idx + 3) % pcm_data.len];
            fifo_a_u32.* = @as(u32, s0) | (@as(u32, s1) << 8) | (@as(u32, s2) << 16) | (@as(u32, s3) << 24);
            idx = (idx + 4) % pcm_data.len; // loop

            // Visual: update square only when crossing rough note boundaries
            const step_samples: usize = (SAMPLE_RATE * 40) / 100; // ~0.40s per note
            const note_idx: usize = if (step_samples > 0) ((idx / step_samples) % 8) else 0;
            if (note_idx != prev_note) {
                prev_note = note_idx;
                const C = @import("gba").Color;
                const colors = [_]C{ C.red, C.lime, C.blue, C.yellow, C.cyan, C.magenta, C.orange, C.green };
                Mode3.rect(.{ 100, 60 }, .{ 140, 100 }, @bitCast(colors[note_idx]));
            }
        }
    }
}
