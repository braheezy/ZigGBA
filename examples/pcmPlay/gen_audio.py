#!/usr/bin/env python3
# Generate a pleasant sine-wave arpeggio for the PCM demo.
# Output: arpeggio_sine_u8_11025.pcm (u8 mono @ 11025 Hz)

import math, struct, subprocess
from pathlib import Path

SR = 11025
DUR_SEC = 30.0
STEP_SEC = 0.40
GAP_SEC = 0.015
ATT = 0.010
DEC = 0.050
SUS = 0.60
REL = 0.080
AMP = 0.85

NOTES = [440.00, 523.25, 659.25, 783.99, 659.25, 523.25, 440.00, 329.63]

def sine(phase):
    return math.sin(2.0 * math.pi * phase)

def adsr(t, length):
    if t < ATT:
        return t / ATT
    t -= ATT
    if t < DEC:
        return 1.0 - (1.0 - SUS) * (t / DEC)
    t -= DEC
    sustain_len = max(0.0, length - (ATT + DEC + REL))
    if t < sustain_len:
        return SUS
    t -= sustain_len
    if t < REL:
        return SUS * (1.0 - t / REL)
    return 0.0

# Generate s16 first
s16 = bytearray()
num_steps = int(DUR_SEC / (STEP_SEC + GAP_SEC))
phase = 0.0
for i in range(num_steps):
    f = NOTES[i % len(NOTES)]
    inc = f / SR
    n_samp = int(STEP_SEC * SR)
    for n in range(n_samp):
        t = n / SR
        a = adsr(t, STEP_SEC)
        s = AMP * a * sine(phase)
        s_i16 = int(max(-1.0, min(1.0, s)) * 32767)
        s16 += struct.pack('<h', s_i16)
        phase = (phase + inc) % 1.0
    # short gap
    s16 += struct.pack('<h', 0) * int(GAP_SEC * SR)

need = int(DUR_SEC * SR)
cur = len(s16) // 2
if cur < need:
    s16 += struct.pack('<h', 0) * (need - cur)
elif cur > need:
    s16 = s16[: need * 2]

script_dir = Path(__file__).parent.resolve()
script_dir.mkdir(parents=True, exist_ok=True)
raw = script_dir / 'arpeggio_raw_s16_11025.s16'
out = script_dir / 'arpeggio_sine_u8_11025.pcm'
raw.write_bytes(s16)

# Convert to u8 with LPF + dither
subprocess.run([
    'ffmpeg','-y','-f','s16le','-ar',str(SR),'-ac','1','-i',str(raw),
    '-af','lowpass=f=4500,aresample=sample_rate=11025:resampler=soxr:dither_method=triangular,volume=0.70,aformat=sample_fmts=u8:channel_layouts=mono',
    '-ar','11025','-ac','1','-f','u8',str(out)
], check=True)
print('Wrote', out)
