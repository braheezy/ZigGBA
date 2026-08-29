//! High-level optional Maxmod audio API.
//!
//! Enable it in `GbaBuild.BuildOptions` before using this namespace.

const enabled = @import("ziggba_build_options").audio_enabled;
/// The underlying Maxmod API, exposed for games that need capabilities beyond
/// ZigGBA's convenience calls (for example custom mix rates or music seeking).
pub const maxmod = if (enabled) @import("maxmod") else struct {};

pub const SoundId = u16;
pub const MusicId = u16;
pub const SoundHandle = if (enabled) maxmod.Sfxhand else u16;
pub const MixMode = if (enabled) maxmod.gba.MixMode else enum(u8) {
    _8khz,
    _10khz,
    _13khz,
    _16khz,
    _18khz,
    _21khz,
    _27khz,
    _31khz,
};

pub const InitOptions = struct {
    /// Simultaneous Maxmod mixing channels; must be from 1 through 32.
    channels: u8 = 8,
};

/// Compile-time configuration for a statically allocated Maxmod runtime.
/// Use this for a non-default mix rate or independent music/effect budgets.
pub const RuntimeConfig = struct {
    mixing_mode: MixMode = ._16khz,
    module_channels: u8 = 8,
    mix_channels: u8 = 8,
};

fn requireEnabled() void {
    if (!enabled) @compileError("gba.audio requires `.build_options = .{ .audio = .{} }` in GbaBuild.addExecutable");
}

/// Returns a statically allocated configurable Maxmod runtime. This is the
/// advanced equivalent of `init`, intended for 13 kHz, 32-channel games.
pub fn Runtime(comptime config: RuntimeConfig) type {
    if (!enabled) @compileError("gba.audio.Runtime requires `.build_options = .{ .audio = .{} }` in GbaBuild.addExecutable");
    return maxmod.gba.Runtime(.{
        .mixing_mode = config.mixing_mode,
        .module_channels = config.module_channels,
        .mix_channels = config.mix_channels,
    });
}

/// Initializes Maxmod with an mmutil-generated soundbank.
pub fn init(soundbank: anytype, options: InitOptions) !void {
    requireEnabled();
    if (options.channels == 0 or options.channels > 32) return error.InvalidChannelCount;
    try maxmod.gba.initDefault(@ptrCast(@constCast(soundbank)), options.channels);
}

/// Advances music/effect mixing once per frame.
pub fn frame() void {
    requireEnabled();
    maxmod.gba.frame();
}

/// Call from the VBlank interrupt handler to reset Maxmod's DMA safely.
pub fn vBlank() void {
    requireEnabled();
    maxmod.mixer.vBlank();
}

/// Starts a sound effect at full volume and returns its handle, or zero when
/// no channel is available.
pub fn playSound(sound: SoundId) SoundHandle {
    return playSoundVolume(sound, 255);
}

/// Starts a sound effect and returns its handle, or zero when no channel is
/// available. `volume` is in Maxmod's 0-255 range.
pub fn playSoundVolume(sound: SoundId, volume: u8) SoundHandle {
    requireEnabled();
    return maxmod.sfx.playAtVolume(sound, volume);
}

/// Returns whether a particular sound-effect handle is still playing.
pub fn isSoundActive(handle: SoundHandle) bool {
    requireEnabled();
    return maxmod.sfx.effectActive(handle);
}

/// Starts a tracker module from the current soundbank and loops it.
pub fn playMusic(music: MusicId) void {
    playMusicMode(music, true);
}

/// Starts a tracker module from the current soundbank. `loop` controls whether
/// the module repeats after its final pattern.
pub fn playMusicMode(music: MusicId, loop: bool) void {
    requireEnabled();
    maxmod.mas.mmStart(music, if (loop) 0 else 1);
}

pub fn stopMusic() void {
    requireEnabled();
    maxmod.mas.mmStop();
}

/// Pauses the current tracker module without resetting its position.
pub fn pauseMusic() void {
    requireEnabled();
    maxmod.mas.mmPause();
}

/// Resumes a tracker module previously paused with `pauseMusic`.
pub fn resumeMusic() void {
    requireEnabled();
    maxmod.mas.mmResume();
}

/// Returns whether the current tracker module is actively playing.
pub fn isMusicPlaying() bool {
    requireEnabled();
    return maxmod.mas.mmActive() != 0;
}
