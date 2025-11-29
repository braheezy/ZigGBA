//! This file is a Zig translation of portions of the Go image package.
//! The core logic is the same, but instead of using interfaces, tagged unions
//! are used to represent different types of images and colors.
const std = @import("std");
const assert = std.debug.assert;

pub const Point = @import("geometry.zig").Point;
pub const Rectangle = @import("geometry.zig").Rectangle;

const image = @import("image.zig");
pub const Image = image.Image;
pub const Config = image.Config;
pub const GrayImage = image.GrayImage;
pub const Gray16Image = image.Gray16Image;
pub const RGBAImage = image.RGBAImage;
pub const RGBA64Image = image.RGBA64Image;
pub const NRGBAImage = image.NRGBAImage;
pub const NRGBA64Image = image.NRGBA64Image;
pub const YCbCrImage = image.YCbCrImage;
pub const CMYKImage = image.CMYKImage;
pub const PalettedImage = image.PalettedImage;
pub const YCbCrSubsample = image.YCbCrSubsample;

pub const Drawer = @import("draw.zig").Drawer;

pub const util = @import("util.zig");
