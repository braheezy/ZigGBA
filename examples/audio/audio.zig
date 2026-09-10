const gba = @import("gba");
const assets = @import("audio_assets");

export var header linksection(".gbaheader") = gba.Header.init("AUDIO", "ZGBA", "00", 0);

var keys: gba.input.BufferedKeysState = .{};
const AudioRuntime = gba.audio.Runtime(.{
    .module_channels = 16,
    .mix_channels = 16,
});
var audio_runtime: AudioRuntime = .{};
var sfx_handle: gba.audio.SoundHandle = 0;
var song_started = false;
var song_paused = false;
var audio_ready = false;
var audio_failed = false;
var audio_started = false;

fn vBlank(_: gba.interrupt.InterruptFlags) callconv(.c) void {
    if (audio_ready) gba.audio.vBlank();
}

fn drawStatus() void {
    const surface = gba.display.getMode3Surface();
    surface.fill(.black);

    const sfx_color = if (audio_ready and gba.audio.isSoundActive(sfx_handle)) gba.ColorRgb555.green else gba.ColorRgb555.white;
    const song_color = if (audio_ready and song_started and !song_paused and gba.audio.isMusicPlaying()) gba.ColorRgb555.green else gba.ColorRgb555.white;
    surface.draw().text("Maxmod audio", .init(gba.ColorRgb555.yellow), .{ .x = 72, .y = 32 });
    surface.draw().text("Press A: play SFX", .init(sfx_color), .{ .x = 48, .y = 72 });
    surface.draw().text("Press B: play/pause XM", .init(song_color), .{ .x = 32, .y = 96 });
    const status = if (audio_failed) "Audio init failed" else "Green = active";
    const status_color = if (audio_failed) gba.ColorRgb555.red else gba.ColorRgb555.white;
    surface.draw().text(status, .init(status_color), .{ .x = 56, .y = 128 });
}

fn ensureAudio() bool {
    if (audio_ready) return true;
    if (audio_failed) return false;
    audio_runtime.init(&assets.soundbank) catch {
        audio_failed = true;
        return false;
    };
    audio_ready = true;
    return true;
}

export fn main() void {
    gba.display.ctrl.* = .initMode3(.{});
    // Draw before initializing audio so a startup failure cannot look like a
    // blank ROM screen.
    drawStatus();
    gba.interrupt.init();
    gba.interrupt.isr_default_redirect = vBlank;

    while (true) {
        keys.poll();
        if (keys.isJustPressed(.A)) {
            // Starting the same effect again intentionally restarts it.
            if (ensureAudio()) {
                sfx_handle = gba.audio.playSound(assets.celeste_level_select);
                audio_started = true;
            }
        }
        if (keys.isJustPressed(.B)) {
            if (!ensureAudio()) {
                // The status line communicates the failure without replacing
                // the UI, so the ROM remains useful for diagnosing assets.
            } else if (!song_started) {
                gba.audio.playMusic(assets.bad_apple);
                song_started = true;
                song_paused = false;
                audio_started = true;
            } else if (song_paused) {
                gba.audio.resumeMusic();
                song_paused = false;
            } else {
                gba.audio.pauseMusic();
                song_paused = true;
            }
        }

        drawStatus();
        // Maxmod only needs mixing once something has started playing.
        if (audio_started) gba.audio.frame();
        gba.bios.vblankIntrWait();
    }
}
