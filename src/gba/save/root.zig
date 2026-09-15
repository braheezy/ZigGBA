//! Reliable, byte-oriented save slots for battery-backed GBA cartridge media.
//!
//! A [`SlotManager`] keeps two complete records for every logical save slot.
//! Each store operation writes and verifies the inactive record before its
//! one-byte commit marker is changed. If power is removed during a store, the
//! preceding valid record remains available on the next boot.

const std = @import("std");
const crc32 = @import("crc32.zig");
const layout = @import("layout.zig");

pub const backend = @import("backend.zig");
pub const sram = @import("sram.zig");
pub const flash = @import("flash.zig");
pub const eeprom = @import("eeprom.zig");

/// Cartridge save hardware selected for a game.
///
/// This is deliberately explicit: the GBA has no reliable way for a ROM to
/// discover its fitted save chip without probing it, and most emulators use
/// conventional marker strings in the ROM to select the same hardware.
pub const Media = enum {
    sram,
    flash_64k,
    flash_128k,
    eeprom_512b,
    eeprom_8k,
};

/// A fixed-width conventional cartridge-save identifier embedded in a ROM.
///
/// Export the value returned by [`romMarker`] from a game so emulators and
/// flash-cart tooling can select the same medium as the save manager. It does
/// not add save hardware to a cartridge; the physical cartridge or flash-cart
/// configuration must still match.
pub const RomMarker = extern struct {
    bytes: [13]u8,
};

/// Return the conventional ROM marker for `media`.
///
/// ```zig
/// export var save_media_marker linksection(".gba_save_marker") = gba.save.romMarker(.sram);
/// ```
pub fn romMarker(comptime media: Media) RomMarker {
    const marker = switch (media) {
        .sram => "SRAM_V113",
        .flash_64k => "FLASH512_V131",
        .flash_128k => "FLASH1M_V103",
        .eeprom_512b, .eeprom_8k => "EEPROM_V124",
    };
    var result: RomMarker = .{ .bytes = @splat(0) };
    @memcpy(result.bytes[0..marker.len], marker);
    return result;
}

/// The fixed shape of every slot in a save file.
///
/// `summary_len` is for small metadata used by a load-game screen, such as a
/// level number, play time, or thumbnail reference. Both buffers passed to
/// [`SlotManager.store`] must exactly match their configured lengths.
pub const Config = struct {
    /// Number of logical save slots.
    slot_count: usize,
    /// Bytes of metadata stored beside every payload.
    summary_len: usize = 0,
    /// Bytes in the game's serialized save data.
    payload_len: usize,
};

/// Values supplied when initializing a save manager.
pub const InitOptions = struct {
    /// A stable, unique name for this game. Changing it intentionally makes
    /// existing records incompatible instead of interpreting them as data for
    /// another game.
    game_id: []const u8,
    /// Increment this when the game's payload format changes incompatibly.
    format_version: u16 = 1,
};

/// The current state of a logical slot.
pub const SlotStatus = enum {
    empty,
    valid,
    corrupt,
    incompatible,
};

/// Storage used by a configured manager, including the reserved recovery copy.
pub const Capacity = struct {
    media_capacity: usize,
    record_size: usize,
    record_stride: usize,
    slot_count: usize,
    used: usize,
    unused: usize,
};

/// Select a hardware backend and create a fixed-shape save manager.
///
/// ```zig
/// const Saves = gba.save.SlotManager(.sram, .{
///     .slot_count = 3,
///     .summary_len = 16,
///     .payload_len = @sizeOf(GameSave),
/// });
/// var saves = try Saves.init(.{ .game_id = "com.example.mygame" });
/// ```
pub fn SlotManager(comptime media: Media, comptime config: Config) type {
    return Manager(backendFor(media), config);
}

/// Create a save manager from a custom backend. This is useful for test
/// harnesses and specialty hardware; games should normally use
/// [`SlotManager`] instead.
pub fn Manager(comptime Backend: type, comptime config: Config) type {
    comptime {
        if (config.slot_count == 0) @compileError("gba.save.Config.slot_count must be greater than zero");
        if (config.slot_count > std.math.maxInt(u16)) @compileError("gba.save.Config.slot_count exceeds the record format limit");
        if (config.payload_len == 0) @compileError("gba.save.Config.payload_len must be greater than zero");
        if (config.summary_len > std.math.maxInt(u16)) @compileError("gba.save.Config.summary_len exceeds the record format limit");
        if (config.payload_len > std.math.maxInt(u32)) @compileError("gba.save.Config.payload_len exceeds the record format limit");
        if (Backend.erase_alignment == 0 or !std.math.isPowerOfTwo(Backend.erase_alignment)) {
            @compileError("save backend erase_alignment must be a non-zero power of two");
        }
    }

    const record_size = layout.header_size + config.summary_len + config.payload_len;
    const record_stride = std.mem.alignForward(usize, record_size, Backend.erase_alignment);
    const total_size = record_stride * config.slot_count * 2;

    comptime {
        if (total_size > Backend.capacity) {
            @compileError(std.fmt.comptimePrint(
                "save configuration needs {d} bytes, but its backend holds {d}",
                .{ total_size, Backend.capacity },
            ));
        }
    }

    return struct {
        const Self = @This();

        /// Errors from the selected medium plus manager-level validation and
        /// recovery results.
        pub const Error = Backend.Error || error{
            InvalidGameId,
            InvalidSlot,
            InvalidBufferLength,
            EmptySlot,
            CorruptSlot,
            IncompatibleSlot,
            WriteVerificationFailed,
        };

        const Candidate = struct {
            record_index: usize,
            header: layout.Header,
        };

        const RecordScan = union(enum) {
            absent,
            candidate: Candidate,
            corrupt,
            incompatible,
        };

        const Selection = struct {
            candidate: ?Candidate = null,
            saw_corrupt: bool = false,
            saw_incompatible: bool = false,
        };

        backend: Backend,
        game_id_hash: u64,
        format_version: u16,

        /// Initialize the manager. This only configures the in-memory driver;
        /// it does not erase, format, or otherwise alter existing save data.
        pub fn init(options: InitOptions) Error!Self {
            if (options.game_id.len == 0 or options.format_version == 0) return error.InvalidGameId;
            return .{
                .backend = Backend.init(),
                .game_id_hash = layout.gameIdHash(options.game_id),
                .format_version = options.format_version,
            };
        }

        /// Return the fixed space reservation made by this save configuration.
        pub fn capacity() Capacity {
            return .{
                .media_capacity = Backend.capacity,
                .record_size = record_size,
                .record_stride = record_stride,
                .slot_count = config.slot_count,
                .used = total_size,
                .unused = Backend.capacity - total_size,
            };
        }

        /// Return a slot's state and, for a valid data slot, copy its summary
        /// into `summary`. Pass `null` when the summary is not needed.
        pub fn slotStatus(self: *Self, slot: usize, summary: ?[]u8) Error!SlotStatus {
            const selection = try self.select(slot);
            const candidate = selection.candidate orelse return selectionStatus(selection);
            if (candidate.header.kind == .empty) return .empty;
            if (summary) |output| {
                if (output.len != config.summary_len) return error.InvalidBufferLength;
                try self.backend.read(recordOffset(slot, candidate.record_index) + layout.header_size, output);
            }
            return .valid;
        }

        /// Load the newest complete copy of `slot` into `payload`.
        ///
        /// The destination must be exactly `Config.payload_len` bytes. A
        /// corrupt newer record is ignored when the previous record verifies.
        pub fn load(self: *Self, slot: usize, payload: []u8) Error!void {
            if (payload.len != config.payload_len) return error.InvalidBufferLength;
            const selection = try self.select(slot);
            const candidate = selection.candidate orelse return switch (selectionStatus(selection)) {
                .empty => error.EmptySlot,
                .corrupt => error.CorruptSlot,
                .incompatible => error.IncompatibleSlot,
                .valid => unreachable,
            };
            if (candidate.header.kind == .empty) return error.EmptySlot;
            try self.backend.read(payloadOffset(slot, candidate.record_index), payload);
        }

        /// Store a new version of `slot` using copy-on-write recovery.
        ///
        /// `summary` and `payload` must exactly match the lengths in `Config`.
        /// The old committed record remains untouched until the new one has
        /// been written and read back successfully.
        pub fn store(self: *Self, slot: usize, summary: []const u8, payload: []const u8) Error!void {
            if (summary.len != config.summary_len or payload.len != config.payload_len) return error.InvalidBufferLength;
            try self.writeRecord(slot, .data, summary, payload);
        }

        /// Atomically mark a slot empty. Its prior data remains as the recovery
        /// copy until the empty record has been verified and committed.
        pub fn eraseSlot(self: *Self, slot: usize) Error!void {
            try self.writeRecord(slot, .empty, &.{}, &.{});
        }

        fn writeRecord(self: *Self, slot: usize, kind: layout.Kind, summary: []const u8, payload: []const u8) Error!void {
            if (slot >= config.slot_count) return error.InvalidSlot;
            if (kind == .data and (summary.len != config.summary_len or payload.len != config.payload_len)) {
                return error.InvalidBufferLength;
            }

            const prior = try self.select(slot);
            const generation: u32 = if (prior.candidate) |candidate| candidate.header.generation +% 1 else 0;
            const record_index: usize = if (prior.candidate) |candidate| 1 - candidate.record_index else 0;
            const offset = recordOffset(slot, record_index);
            const header = layout.Header{
                .format_version = self.format_version,
                .game_id_hash = self.game_id_hash,
                .slot_index = @intCast(slot),
                .summary_len = @intCast(config.summary_len),
                .payload_len = @intCast(config.payload_len),
                .generation = generation,
                .summary_crc = if (kind == .data) crc32.checksum(summary) else 0,
                .payload_crc = if (kind == .data) crc32.checksum(payload) else 0,
                .kind = kind,
                .state = .writing,
            };
            var header_bytes: [layout.header_size]u8 = undefined;
            layout.encode(header, &header_bytes);

            try self.backend.erase(offset, record_stride);
            try self.backend.write(offset, &header_bytes);
            if (kind == .data) {
                try self.backend.write(offset + layout.header_size, summary);
                try self.backend.write(offset + layout.header_size + config.summary_len, payload);
            }

            try self.verifyStaged(slot, record_index, header);
            const final_state = [_]u8{switch (kind) {
                .data => @intFromEnum(layout.State.valid),
                .empty => @intFromEnum(layout.State.empty),
            }};
            try self.backend.write(offset + layout.state_offset, &final_state);

            const committed = try self.scanRecord(slot, record_index);
            switch (committed) {
                .candidate => |candidate| {
                    if (candidate.header.generation != generation or candidate.header.kind != kind) {
                        return error.WriteVerificationFailed;
                    }
                },
                else => return error.WriteVerificationFailed,
            }
        }

        fn verifyStaged(self: *Self, slot: usize, record_index: usize, expected: layout.Header) Error!void {
            const offset = recordOffset(slot, record_index);
            var header_bytes: [layout.header_size]u8 = undefined;
            try self.backend.read(offset, &header_bytes);
            const actual = layout.decode(&header_bytes) catch return error.WriteVerificationFailed;
            if (actual.state != .writing or
                actual.kind != expected.kind or
                actual.generation != expected.generation or
                actual.format_version != expected.format_version or
                actual.game_id_hash != expected.game_id_hash or
                actual.slot_index != expected.slot_index or
                actual.summary_len != expected.summary_len or
                actual.payload_len != expected.payload_len or
                actual.summary_crc != expected.summary_crc or
                actual.payload_crc != expected.payload_crc)
            {
                return error.WriteVerificationFailed;
            }
            if (actual.kind == .data) {
                if (try self.checksumRange(offset + layout.header_size, config.summary_len) != actual.summary_crc) {
                    return error.WriteVerificationFailed;
                }
                if (try self.checksumRange(offset + layout.header_size + config.summary_len, config.payload_len) != actual.payload_crc) {
                    return error.WriteVerificationFailed;
                }
            }
        }

        fn select(self: *Self, slot: usize) Error!Selection {
            if (slot >= config.slot_count) return error.InvalidSlot;
            var selection: Selection = .{};
            for (0..2) |record_index| {
                switch (try self.scanRecord(slot, record_index)) {
                    .absent => {},
                    .corrupt => selection.saw_corrupt = true,
                    .incompatible => selection.saw_incompatible = true,
                    .candidate => |candidate| {
                        if (selection.candidate == null or layout.isNewerGeneration(
                            candidate.header.generation,
                            selection.candidate.?.header.generation,
                        )) {
                            selection.candidate = candidate;
                        }
                    },
                }
            }
            return selection;
        }

        fn scanRecord(self: *Self, slot: usize, record_index: usize) Error!RecordScan {
            const offset = recordOffset(slot, record_index);
            var header_bytes: [layout.header_size]u8 = undefined;
            try self.backend.read(offset, &header_bytes);
            if (std.mem.allEqual(u8, &header_bytes, 0xff)) return .absent;
            if (!std.mem.eql(u8, header_bytes[0..8], "ZGGBASAV")) return .absent;

            const header = layout.decode(&header_bytes) catch return .corrupt;
            if (header.state == .writing) return .corrupt;
            if (header.format_version != self.format_version or
                header.game_id_hash != self.game_id_hash or
                header.slot_index != slot or
                header.summary_len != config.summary_len or
                header.payload_len != config.payload_len)
            {
                return .incompatible;
            }
            switch (header.kind) {
                .data => {
                    if (header.state != .valid) return .corrupt;
                    if (try self.checksumRange(offset + layout.header_size, config.summary_len) != header.summary_crc) return .corrupt;
                    if (try self.checksumRange(offset + layout.header_size + config.summary_len, config.payload_len) != header.payload_crc) return .corrupt;
                },
                .empty => if (header.state != .empty) return .corrupt,
            }
            return .{ .candidate = .{ .record_index = record_index, .header = header } };
        }

        fn checksumRange(self: *Self, offset: usize, len: usize) Error!u32 {
            var checksum_state: crc32.Crc32 = .{};
            var bytes: [64]u8 = undefined;
            var read: usize = 0;
            while (read < len) {
                const count = @min(bytes.len, len - read);
                try self.backend.read(offset + read, bytes[0..count]);
                checksum_state.update(bytes[0..count]);
                read += count;
            }
            return checksum_state.final();
        }

        fn recordOffset(slot: usize, record_index: usize) usize {
            return (slot * 2 + record_index) * record_stride;
        }

        fn payloadOffset(slot: usize, record_index: usize) usize {
            return recordOffset(slot, record_index) + layout.header_size + config.summary_len;
        }

        fn selectionStatus(selection: Selection) SlotStatus {
            if (selection.saw_incompatible) return .incompatible;
            if (selection.saw_corrupt) return .corrupt;
            return .empty;
        }
    };
}

fn backendFor(comptime media: Media) type {
    return switch (media) {
        .sram => sram.Backend,
        .flash_64k => flash.Flash64Backend,
        .flash_128k => flash.Flash128Backend,
        .eeprom_512b => eeprom.Eeprom512Backend,
        .eeprom_8k => eeprom.Eeprom8kBackend,
    };
}
