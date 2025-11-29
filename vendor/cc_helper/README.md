This is a resurrection of `zig objcopy` as it was in `zig 0.14.1`, but ported to `zig 0.15.1`

It is very limited (see https://github.com/ziglang/zig/issues/24522), but still usefull to me..


# usage:

in `build.zig.zon` :
```zig
.{
    .dependencies = .{
        .cc_helper = .{
            .url = "git+https://codeberg.org/xbx/cc_helper.git#1076ea283acb25974346acd467599aeaf832ed01",
            .hash = "cc_helper-0.0.1-JfF0JHEqAQDP3PvsaYXbQOjpZthAR5AOTwGDdZebxyRE",
        },
    },
}
```

in `build.zig` :
```zig
    const cc_helper = @import("cc_helper");

    const exe = b.addExecutable(...);

    cc_helper.installStripedElfExe(b, exe, .{
        .strip = .debug_and_symbols,
        .extract_to_separate_file = true,
    });
```


(instead of
```zig
const stripped_exe = b.addObjCopy(exe.getEmittedBin(), .{...});
b.getInstallStep().dependOn(&b.addInstallBinFile(stripped_exe.getOutput(), exe.out_filename).step);`
```
)

# manual invocation:
It is also possible to invoke manually the command with
```zig
    const objcopy = b.dependency("cc_helper", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("objcopy");

    const run_objcopy = b.addRunArtifact(objcopy);
    run_objcopy.addArgs(&.{ ... });
    run_objcopy.addFileArg(exe.getEmittedBin());
    const stripped_exe = run_objcopy.addOutputFileArg(exe.out_filename);
    b.getInstallStep().dependOn(&b.addInstallBinFile(stripped_exe, exe.out_filename).step);
```
