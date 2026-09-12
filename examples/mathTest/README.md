# Math regression tests

This ROM currently tests only `arctan2`. It and the host test use the same 100 input pairs from
`src/gba/test/bios_arctan2.zig`. They cover zero, axes, diagonals, all four
quadrants, and signed 16-bit boundaries—not every possible input pair.
Expected angles are calculated at compile time using floating-point `atan2`.
Axes and diagonals must match exactly; other angles allow four angle units
(about 0.022 degrees) for the BIOS's integer approximation. This checks
numerical accuracy, not bit-for-bit equivalence with the original BIOS.

## Run on the host

```sh
zig test src/gba/test.zig --test-filter 'BIOS arctan2'
```

The host test exercises the software fallback; the ROM exercises the BIOS call.

## Run the ROM

```sh
zig build
mgba -C useBios=0 zig-out/mathTest.gba
```

On macOS, the executable may be at
`/Applications/mGBA.app/Contents/MacOS/mGBA` rather than on your PATH.
The screen is green when every case passes and red otherwise. The emulator's
debug log reports each failure and the final count.

The command above uses mGBA's emulated BIOS. To check the original BIOS,
run with your own BIOS dump using `mgba -b /path/to/gba_bios.bin -C useBios=1
zig-out/mathTest.gba`, or run the ROM on a GBA. An emulated-BIOS result
does not establish behavior on physical hardware.
