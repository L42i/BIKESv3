#!/usr/bin/env python3
"""Render placeholder speech with espeak-ng into media/flock/sentence_N_voice_M.wav.

Reads sentences.txt (N|event|text). The real Kokoro corpus uses the same file
names and replaces these files; nothing else changes.

Usage: python3 make_placeholder_corpus.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SENTENCES = os.path.join(HERE, "sentences.txt")
MEDIA = os.path.join(HERE, "..", "..", "media", "flock")
VOICES = ["en-us", "en-us+f3", "en-gb"]
RATE = 48000


def read_sentences():
    with open(SENTENCES) as f:
        rows = [line.strip().split("|", 2) for line in f if line.strip()]
    return [(int(n), text) for n, _, text in rows]


def render(text, voice, path):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        subprocess.run(["espeak-ng", "-v", voice, "-w", tmp.name, text], check=True)
        with wave.open(tmp.name) as w:
            rate = w.getframerate()
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float)
            channels = w.getnchannels()
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    times = np.arange(int(len(samples) * RATE / rate)) * rate / RATE
    resampled = np.interp(times, np.arange(len(samples)), samples).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(resampled.tobytes())


def main():
    if not shutil.which("espeak-ng"):
        sys.exit("espeak-ng is missing. Install it with: sudo apt install espeak-ng")
    os.makedirs(MEDIA, exist_ok=True)
    for n, text in read_sentences():
        for m, voice in enumerate(VOICES, start=1):
            path = os.path.join(MEDIA, f"sentence_{n}_voice_{m}.wav")
            render(text, voice, path)
            print(os.path.relpath(path, HERE), voice, text, flush=True)


if __name__ == "__main__":
    main()
