const gba = @import("gba");

export var header linksection(".gbaheader") = gba.initHeader("PCMDEMO", "APPE", "00", 0);

// External PCM asset (u8 mono @ 11025 Hz). Generate via gen_audio.py in this folder.
const SAMPLE_RATE: u32 = 11_025;
const pcm_data = @embedFile("arpeggio_sine_u8_11025.pcm");
const Mode3 = @import("gba").bitmap.Mode3;

// ---- Small helpers (candidates to lift into the library) ----
const FIFO_A_ADDR: usize = gba.mem.io + 0x00A0;
const CPU_FREQ: u32 = 16_777_216;

// DMA control (upper halfword) symbolic bits
const DMA_DEST_FIXED: u32 = 2 << 21;
const DMA_SRC_INC: u32 = 0 << 23;
const DMA_REPEAT: u32 = 1 << 25;
const DMA_WORD: u32 = 1 << 26;
const DMA_START_SPECIAL: u32 = 3 << 28;
const DMA_ENABLE: u32 = 1 << 31;

fn timerReloadForSampleRate(sample_rate: u32) u16 {
    return @intCast(@as(u32, 65536) - (CPU_FREQ / sample_rate));
}

fn setupDirectSoundAUsingTimer(timer_index: u1) void {
    gba.sound.dsound.* = .{
        .volume_dmg = .percent_100,
        .volume_a = .percent_100,
        .left_a = .enable,
        .right_a = .enable,
        .timer_a = timer_index,
        .reset_a = false,
    };
}

fn startDma1ToFifoA(src_start: usize) void {
    var dma1: *volatile gba.mem.Dma = @ptrCast(&gba.mem.dma[1]);
    dma1.source = @ptrFromInt(src_start);
    dma1.dest = @ptrFromInt(FIFO_A_ADDR);
    const ctrl: u32 = DMA_DEST_FIXED | DMA_SRC_INC | DMA_REPEAT | DMA_WORD | DMA_START_SPECIAL | DMA_ENABLE | 4; // count=4
    const dma1_ctrl_u32: *volatile u32 = @ptrCast(&dma1.ctrl);
    dma1_ctrl_u32.* = ctrl;
}

pub export fn main() void {
    gba.interrupt.init();
    _ = gba.interrupt.add(.vblank, null);

    gba.display.ctrl.* = .{ .mode = .mode3, .bg2 = .enable };
    Mode3.fill(@bitCast(gba.Color.rgb(4, 4, 4)));
    // Master sound on
    gba.sound.status.* = .{ .master = .enable };

    // Bias mid-level (0x100 center for 9-bit field), 32.768 kHz
    gba.sound.bias.* = .{ .level = 0x100, .cycle = .bits_9 };

    // Timer0 at SAMPLE_RATE, enable last (write counter first)
    const reload: u16 = timerReloadForSampleRate(SAMPLE_RATE);
    gba.timer.timers[0].counter = reload;
    gba.timer.timers[0].ctrl = .{ .freq = .cycles_1, .mode = .freq, .enable = .enable };

    // DirectSound A using Timer0; set DMG mixer to max volume
    gba.sound.dmg.* = .{ .left_volume = 7, .right_volume = 7 };
    setupDirectSoundAUsingTimer(0);

    // Stream directly from ROM so we can play the full arpeggio
    const src_start: usize = @intFromPtr(pcm_data.ptr);
    // Configure DMA1 to feed FIFO A in special (FIFO) timing, 32-bit, repeat, dest fixed.
    startDma1ToFifoA(src_start);

    // Loop forever, re-arm at ROM start every frame (conservative)
    // and update a colored square approximately once per note
    var frames: u32 = 0;
    const frames_per_note: u32 = 25; // ~0.415s at 60fps
    var note_idx: u32 = 0;

    const C = gba.Color;
    const colors = [_]C{ C.red, C.blue, C.lime, C.yellow, C.cyan, C.magenta, C.orange, C.green };
    while (true) {
        gba.display.vSync();
        // re-arm source for simplicity; DMA continues FIFO timing
        gba.mem.dma[1].source = @ptrFromInt(src_start);
        frames += 1;
        if (frames >= frames_per_note) {
            frames = 0;
            note_idx = (note_idx + 1) % 8;
            Mode3.rect(.{ 100, 60 }, .{ 140, 100 }, @bitCast(colors[note_idx]));
        }
    }
}
