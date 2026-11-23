const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    // TODO: zpix can just live in the tool eventually
    const zpix = b.createModule(.{
        .root_source_file = b.path("../../build/zpix/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "zpix", .module = zpix }},
    });
    const exe = b.addExecutable(.{
        .name = "ziggba-pack",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run ziggba-pack");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test image loading and command arguments").dependOn(&b.addRunArtifact(tests).step);
}
