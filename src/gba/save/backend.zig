//! Internal contract shared by save-media backends.

/// Errors a backend may return while accessing save media.
pub const Error = error{
    OutOfBounds,
    WriteFailed,
    EraseFailed,
    VerifyFailed,
    Timeout,
    UnsupportedDevice,
};
