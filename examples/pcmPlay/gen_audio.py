#!/usr/bin/env python3
# Generate a pleasant sine-wave arpeggio for the PCM demo.
# Output: arpeggio_sine_u8_11025.pcm (u8 mono @ 11025 Hz)

import math, struct, subprocess
from pathlib import Path

SR_SRC = 48000   # synth sample-rate (higher for smoother envelopes)
SR_OUT = 11025   # output sample-rate for GBA
DUR_SEC = 30.0
STEP_SEC = 0.40
GAP_SEC = 0.015
FADE_IN = 0.008   # raised-cosine fade-in (s)
FADE_OUT = 0.012  # raised-cosine fade-out (s)
SUS = 0.70
AMP = 0.60

NOTES = [440.00, 523.25, 659.25, 783.99, 659.25, 523.25, 440.00, 329.63]

def sine(phase):
    return math.sin(2.0 * math.pi * phase)

def raised_cos(x):
    # 0..1 -> 0..1 smooth (half-cosine)
    return 0.5 - 0.5*math.cos(math.pi*max(0.0, min(1.0, x)))

def smooth_env(t, length):
    # Raised-cosine fade in/out around a flat sustain at SUS
    env_in = raised_cos(t/FADE_IN)
    env_out = 1.0 - raised_cos((t - (length-FADE_OUT))/FADE_OUT)
    base = SUS
    return max(0.0, min(1.0, base*min(env_in, env_out)))

# Generate s16 first
s16 = bytearray()
num_steps = int(DUR_SEC / (STEP_SEC + GAP_SEC))
phase = 0.0
for i in range(num_steps):
    f = NOTES[i % len(NOTES)]
    inc = f / SR_SRC
    n_samp = int(STEP_SEC * SR_SRC)
    for n in range(n_samp):
        t = n / SR_SRC
        a = smooth_env(t, STEP_SEC)
        s = AMP * a * sine(phase)
        s_i16 = int(max(-1.0, min(1.0, s)) * 32767)
        s16 += struct.pack('<h', s_i16)
        phase = (phase + inc) % 1.0
    # short gap
    # optional tiny gap (already faded-out)
    s16 += struct.pack('<h', 0) * int(GAP_SEC * SR_SRC)

need = int(DUR_SEC * SR_SRC)
cur = len(s16) // 2
if cur < need:
    s16 += struct.pack('<h', 0) * (need - cur)
elif cur > need:
    s16 = s16[: need * 2]

script_dir = Path(__file__).parent.resolve()
script_dir.mkdir(parents=True, exist_ok=True)
raw = script_dir / 'arpeggio_raw_s16_44100.s16'
out = script_dir / 'arpeggio_sine_u8_11025.pcm'
raw.write_bytes(s16)

# Convert to u8 with stronger LPF, soxr resample, high-pass triangular dither, and headroom
subprocess.run([
    'ffmpeg','-y','-f','s16le','-ar',str(SR_SRC),'-ac','1','-i',str(raw),
    '-af','lowpass=f=3200,aresample=sample_rate=' + str(SR_OUT) + ':resampler=soxr:precision=28:dither_method=triangular_hp,volume=0.60,aformat=sample_fmts=u8:channel_layouts=mono',
    '-ar',str(SR_OUT),'-ac','1','-f','u8',str(out)
], check=True)
print('Wrote', out)
