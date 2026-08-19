const gba = @import("../gba.zig");

const build_options = @import("ziggba_build_options");

// Imports related to "agbprint"/"gbaprint" logging.
pub const reg_agb_print_protect = @import("agb.zig").reg_agb_print_protect;
pub const reg_agb_print_context = @import("agb.zig").reg_agb_print_context;
pub const reg_agb_print_buffer = @import("agb.zig").reg_agb_print_buffer;
pub const agb_buffer_size = @import("agb.zig").agb_buffer_size;
pub const AgbPrintContext = @import("agb.zig").AgbPrintContext;
pub const agbInit = @import("agb.zig").agbInit;
pub const agbPrint = @import("agb.zig").agbPrint;
pub const agbWrite = @import("agb.zig").agbWrite;

// Imports related to mGBA logging.
pub const MgbaLogLevel = @import("mgba.zig").MgbaLogLevel;
pub const reg_mgba_log_str_size = @import("mgba.zig").reg_mgba_log_str_size;
pub const reg_mgba_log_enabled = @import("mgba.zig").reg_mgba_log_enabled;
pub const reg_mgba_log_str = @import("mgba.zig").reg_mgba_log_str;
pub const reg_mgba_log_level = @import("mgba.zig").reg_mgba_log_level;
pub const reg_mgba_log_enable = @import("mgba.zig").reg_mgba_log_enable;
pub const mgbaPrint = @import("mgba.zig").mgbaPrint;
pub const mgbaWrite = @import("mgba.zig").mgbaWrite;
pub const mgbaPrintInfo = @import("mgba.zig").mgbaPrintInfo;
pub const mgbaWriteInfo = @import("mgba.zig").mgbaWriteInfo;
pub const mgbaPrintWarning = @import("mgba.zig").mgbaPrintWarning;
pub const mgbaWriteWarning = @import("mgba.zig").mgbaWriteWarning;
pub const mgbaPrintError = @import("mgba.zig").mgbaPrintError;
pub const mgbaWriteError = @import("mgba.zig").mgbaWriteError;
pub const mgbaPrintFatal = @import("mgba.zig").mgbaPrintFatal;
pub const mgbaWriteFatal = @import("mgba.zig").mgbaWriteFatal;

// Panic-related imports.
pub const std_panic = @import("panic.zig").std_panic;
pub const stdPanicHandler = @import("panic.zig").stdPanicHandler;
pub const panic = @import("panic.zig").panic;

/// Enumeration of supported logger interfaces.
pub const LoggerInterface = enum {
    /// No default logger.
    /// Corresponds to `stubInit`, `stubPrint`, and `stubWrite`.
    none,
    /// Represents the "agbprint"/"gbaprint" logging interface.
    /// Corresponds to `agbInit`, `agbPrint`, and `agbWrite`.
    agb,
    /// Represents the mGBA logging interface.
    /// Corresponds to `stubInit`, `mgbaPrintInfo`, and `mgbaWriteInfo`.
    mgba,
};

/// Stub function for `gba.debug.init`. Does nothing.
fn stubInit() void {}

/// Stub function for `gba.debug.print`. Does nothing.
fn stubPrint(comptime _: []const u8, _: anytype) void {}

/// Stub function for `gba.debug.write`. Does nothing.
fn stubWrite(_: []const u8) void {}

/// Initialize the default logger, as configured
/// via ZigGBA's build options.
/// This may or may not be strictly necessary, depending on the emulator
/// and the chosen logger.
pub const init = switch (build_options.default_logger) {
    .none => stubInit,
    .agb => agbInit,
    .mgba => stubInit,
};

/// Log a formatted message using the default logger, as configured
/// via ZigGBA's build options.
pub const print = switch (build_options.default_logger) {
    .none => stubPrint,
    .agb => agbPrint,
    .mgba => mgbaPrintInfo,
};

/// Log a message string using the default logger, as configured
/// via ZigGBA's build options.
pub const write = switch (build_options.default_logger) {
    .none => stubWrite,
    .agb => agbWrite,
    .mgba => mgbaWriteInfo,
};
