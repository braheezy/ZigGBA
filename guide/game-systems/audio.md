# Audio

ZigGBA's Maxmod integration is optional. Enable it per executable with
`build_options = .{ .audio = .{} }`, create a soundbank through
`createAudioAssetModule`, and call `gba.audio.init` with the generated
soundbank. `addSound` accepts WAV effects; `addMusic` accepts tracker modules
such as XM, MOD, S3M, and IT.

See [`examples/audio`](../../examples/audio/) for a complete minimal ROM: A
replays a WAV effect, while B starts, pauses, and resumes a looping XM track.

Call `gba.audio.frame()` once per frame and `gba.audio.vBlank()` from your
VBlank interrupt handler. This keeps Maxmod's DMA reset inside VBlank.

For a custom mix rate or separate music/effect-channel budgets, use
`gba.audio.Runtime(.{ .mixing_mode = ._13khz, .module_channels = 32,
.mix_channels = 32 })`. The lower-level Maxmod controls remain available as
`gba.audio.maxmod` for seeking, transitions, and other advanced policies.
