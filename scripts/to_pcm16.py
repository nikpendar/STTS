#!/usr/bin/env python3
"""Converts a mono 32-bit float WAV (as shipped by FLEURS) to 16-bit PCM WAV.

Usage: to_pcm16.py <in.wav> <out.wav>. Prints the duration in seconds.
"""
import array
import struct
import sys
import wave

src, dst = sys.argv[1:]
data = open(src, "rb").read()
pos, rate, channels, fmt, samples = 12, 16000, 1, 1, None
while pos < len(data):
    chunk, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
    body = data[pos + 8:pos + 8 + size]
    if chunk == b"fmt ":
        fmt, channels, rate = struct.unpack("<HHI", body[:8])
        bits = struct.unpack("<H", body[14:16])[0]
    elif chunk == b"data":
        samples = body
    pos += 8 + size + (size & 1)
if fmt == 3 and bits == 32:
    floats = array.array("f", samples)
    pcm = array.array("h", (max(-32768, min(32767, int(x * 32767))) for x in floats[::channels]))
elif fmt == 1 and bits == 16:
    pcm = array.array("h", samples)[::channels]
else:
    sys.exit(f"unsupported format {fmt}/{bits}")
if rate != 16000:
    sys.exit(f"unsupported sample rate {rate}")
with wave.open(dst, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(pcm.tobytes())
print(f"{len(pcm) / rate:.2f}")
