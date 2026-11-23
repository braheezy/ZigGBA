//! Experimental build integration for the host-side asset processor.
const std = @import("std");

/// package_root belongs to ZigGBA, while b may belong to a consuming game.
pub fn createExecutable(b: *std.Build, package_root: std.Build.LazyPath) *std.Build.Step.Compile {
    const zpix = b.createModule(.{
        .root_source_file = package_root.path(b, "build/zpix/root.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    return b.addExecutable(.{
        .name = "ziggba-pack",
        .root_module = b.createModule(.{
            .root_source_file = package_root.path(b, "tools/ziggba-pack/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zpix", .module = zpix }},
        }),
    });
}

/// Capture the image-info ZON as a cacheable generated file.
/// The image bytes, rather than just the path string, are tracked as input.
pub fn addImageInfo(b: *std.Build, tool: *std.Build.Step.Compile, source_file: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArgs(&.{ "image-info", "--input" });
    run.addFileArg(source_file);
    return run.captureStdOut(.{ .basename = "image-info.zon" });
}
