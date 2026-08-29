//! Opt-in Maxmod audio support and mmutil-backed soundbank assets.

const std = @import("std");

/// Add Maxmod's GBA module and mixer object to ZigGBA's runtime module.
///
/// `maxmod-zig` is deliberately lazy: non-audio ROMs neither fetch nor link
/// it. A null result means Zig is fetching it and will configure again.
pub fn addMaxmodRuntime(b: *std.Build, gba_module: *std.Build.Module, _: u8) ?*std.Build.Module {
    const maxmod_dep = b.lazyDependency("maxmod_zig", .{}) orelse return null;
    const options = b.addOptions();
    // maxmod-zig currently requires this option module for its debug hooks.
    options.addOption(bool, "xm_debug", false);
    const maxmod_module = b.createModule(.{
        .root_source_file = maxmod_dep.path("src/maxmod.zig"),
        .target = gba_module.resolved_target.?,
        .optimize = gba_module.optimize.?,
    });
    maxmod_module.addObjectFile(maxmod_dep.path("src/mixer_asm.o"));
    maxmod_module.addOptions("build_options", options);
    maxmod_module.addImport("gba", gba_module);
    gba_module.addImport("maxmod", maxmod_module);
    return maxmod_module;
}

/// One mmutil-generated soundbank, exposed to game code as a Zig module.
pub const AssetModule = struct {
    const Entry = struct {
        name: []const u8,
        kind: enum { sound, music },
        id: u16,
    };

    b: *std.Build,
    consumer_module: *std.Build.Module,
    gba_module: *std.Build.Module,
    run: ?*std.Build.Step.Run,
    entries: std.ArrayList(Entry) = .empty,
    next_sound: u16 = 0,
    next_music: u16 = 0,
    module: ?*std.Build.Module = null,

    pub fn create(b: *std.Build, consumer_module: *std.Build.Module, gba_module: *std.Build.Module) *AssetModule {
        const assets = b.allocator.create(AssetModule) catch @panic("OOM");
        const mmutil_dep = b.lazyDependency("mmutil_zig", .{});
        assets.* = .{
            .b = b,
            .consumer_module = consumer_module,
            .gba_module = gba_module,
            .run = if (mmutil_dep) |dep| b.addRunArtifact(dep.artifact("mmutil-zig")) else null,
        };
        return assets;
    }

    /// Adds a WAV sound effect. Its generated `SoundId` is available as
    /// `assets.<name>` after `addImport`.
    pub fn addSound(self: *AssetModule, name: []const u8, source_file: std.Build.LazyPath) void {
        self.add(name, source_file, .sound);
    }

    /// Adds a tracker module (`.xm`, `.mod`, `.s3m`, or `.it`). Its generated
    /// `MusicId` is available as `assets.<name>` after `addImport`.
    pub fn addMusic(self: *AssetModule, name: []const u8, source_file: std.Build.LazyPath) void {
        self.add(name, source_file, .music);
    }

    fn add(self: *AssetModule, name: []const u8, source_file: std.Build.LazyPath, kind: Entry.kind) void {
        if (self.module != null) @panic("cannot add an audio asset after AssetModule.addImport");
        if (!std.zig.isValidId(name)) std.debug.panic("audio asset name '{s}' is not a valid Zig identifier", .{name});
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) std.debug.panic("audio asset module already contains an asset named '{s}'", .{name});
        const id = switch (kind) {
            .sound => blk: {
                defer self.next_sound += 1;
                break :blk self.next_sound;
            },
            .music => blk: {
                defer self.next_music += 1;
                break :blk self.next_music;
            },
        };
        if (self.run) |run| run.addFileArg(source_file);
        self.entries.append(self.b.allocator, .{ .name = name, .kind = kind, .id = id }) catch @panic("OOM");
    }

    /// Imports the generated soundbank module. It exposes `soundbank`, plus a
    /// typed ID for every asset registered with `addSound` or `addMusic`.
    pub fn addImport(self: *AssetModule, import_name: []const u8) void {
        if (self.module) |module| {
            self.consumer_module.addImport(import_name, module);
            return;
        }
        const run = self.run orelse return;
        const soundbank = run.addOutputFileArg("soundbank.bin");
        var source: std.ArrayList(u8) = .empty;
        source.appendSlice(
            self.b.allocator,
            "/// mmutil-generated Maxmod soundbank. Pass this to `gba.audio.init`.\n" ++
                "pub const soundbank align(4) = @embedFile(\"soundbank.bin\").*;\n",
        ) catch @panic("OOM");
        for (self.entries.items) |entry| {
            const type_name = switch (entry.kind) {
                .sound => "gba.audio.SoundId",
                .music => "gba.audio.MusicId",
            };
            source.writer(self.b.allocator).print("pub const {s}: {s} = {d};\n", .{ entry.name, type_name, entry.id }) catch @panic("OOM");
        }
        const files = self.b.addWriteFiles();
        const module = self.b.createModule(.{ .root_source_file = files.add("audio_assets.zig", source.items) });
        module.addAnonymousImport("soundbank.bin", .{ .root_source_file = soundbank });
        module.addImport("gba", self.gba_module);
        self.module = module;
        self.consumer_module.addImport(import_name, module);
    }
};
