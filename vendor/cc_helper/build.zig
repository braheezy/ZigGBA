const std = @import("std");

pub const Strip = enum {
    none,
    debug,
    debug_and_symbols,
};
const StripOptions = struct {
    strip: enum { none, debug, debug_and_symbols } = .debug_and_symbols,

    extract_to_separate_file: bool = true,
    debug_ext: []const u8 = ".debug",
};
pub fn installStripedElfExe(b: *std.Build, artifact: *std.Build.Step.Compile, opt: StripOptions) void {
    if (opt.strip == .none) {
        b.installArtifact(artifact);
        return;
    }

    const objcopy = b.dependencyFromBuildZig(@This(), .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("objcopy");

    const run_objcopy = b.addRunArtifact(objcopy);

    switch (opt.strip) {
        .none => unreachable,
        .debug => run_objcopy.addArgs(&.{"--strip-debug"}),
        .debug_and_symbols => run_objcopy.addArgs(&.{"--strip-all"}),
    }

    if (opt.extract_to_separate_file) {
        const debug_filename = b.fmt("{s}{s}", .{ artifact.out_filename, opt.debug_ext });
        run_objcopy.addArgs(&.{"--extract-to"});
        const debug_bin = run_objcopy.addOutputFileArg(debug_filename);
        b.getInstallStep().dependOn(&b.addInstallBinFile(debug_bin, debug_filename).step);
    }

    run_objcopy.addFileArg(artifact.getEmittedBin());
    const stripped_exe = run_objcopy.addOutputFileArg(artifact.out_filename);

    b.getInstallStep().dependOn(&b.addInstallBinFile(stripped_exe, artifact.out_filename).step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("objcopy", .{
        .root_source_file = b.path("src/objcopy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "objcopy",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
