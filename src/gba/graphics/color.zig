//! Color values stored in the GBA's native 15-bit RGB format.

/// Represents 16-bit color in a GBA-friendly format.
pub const ColorRgb555 = packed struct(u16) {
    /// Opaque black.
    pub const black = ColorRgb555.rgb(0, 0, 0);
    /// Opaque white.
    pub const white = ColorRgb555.rgb(31, 31, 31);
    /// Opaque red at maximum intensity.
    pub const red = ColorRgb555.rgb(31, 0, 0);
    /// Opaque green at maximum intensity.
    pub const green = ColorRgb555.rgb(0, 31, 0);
    /// Opaque blue at maximum intensity.
    pub const blue = ColorRgb555.rgb(0, 0, 31);
    /// Opaque yellow at maximum intensity.
    pub const yellow = ColorRgb555.rgb(31, 31, 0);
    /// Opaque cyan at maximum intensity.
    pub const cyan = ColorRgb555.rgb(0, 31, 31);
    /// Opaque magenta at maximum intensity.
    pub const magenta = ColorRgb555.rgb(31, 0, 31);

    /// Intensity in red color channel.
    r: u5 = 0,
    /// Intensity in green color channel.
    g: u5 = 0,
    /// Intensity in blue color channel.
    b: u5 = 0,
    /// Unused padding bit.
    _: u1 = 0,

    /// Initialize a color with red, green, and blue values.
    /// A value of 0 represents the darkest color in a channel,
    /// and a value of 31 represents the brighest.
    pub fn rgb(r: u5, g: u5, b: u5) ColorRgb555 {
        return .{
            .r = r,
            .g = g,
            .b = b,
        };
    }
};
