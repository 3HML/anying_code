"""Convert uncompressed PCM WAV to MUSIC.WAV (Python 3.8-3.12).

Usage: python prepare_music.py input.wav output_directory
The destination must not already contain MUSIC.WAV. Copy the result to the
FAT32 card root alongside existing pictures; this tool never writes sectors.
"""
from pathlib import Path
import argparse
import audioop
import hashlib
import json
import os
import tempfile
import wave


def convert(source, directory):
    source, directory = Path(source), Path(directory)
    destination = directory / "MUSIC.WAV"
    if destination.exists():
        raise FileExistsError(str(destination))
    directory.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with wave.open(str(source), "rb") as src:
            channels, width, rate = src.getnchannels(), src.getsampwidth(), src.getframerate()
            if src.getcomptype() != "NONE" or channels not in (1, 2) or width not in (1, 2, 3, 4):
                raise ValueError("Input must be integer PCM WAV, mono/stereo, 8/16/24/32-bit")
            if not 8000 <= rate <= 192000 or src.getnframes() == 0:
                raise ValueError("Input rate must be 8000..192000 Hz and contain samples")
            fd, temp = tempfile.mkstemp(prefix="music_", suffix=".wav", dir=directory)
            os.close(fd)
            state = None
            with wave.open(temp, "wb") as dst:
                dst.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
                while True:
                    data = src.readframes(65536)
                    if not data:
                        break
                    # WAV 8-bit samples are unsigned; wider PCM is signed.
                    if width == 1:
                        data = audioop.bias(data, 1, -128)
                    if channels == 2:
                        data = audioop.tomono(data, width, 0.5, 0.5)
                    if width != 2:
                        data = audioop.lin2lin(data, width, 2)
                    if rate != 48000:
                        data, state = audioop.ratecv(data, 2, 1, rate, 48000, state)
                    dst.writeframesraw(data)
            with wave.open(temp, "rb") as check:
                frames = check.getnframes()
                assert check.getparams()[:3] == (1, 2, 48000) and frames > 0
            if Path(temp).stat().st_size > 536870910:
                raise ValueError("Output exceeds the player's 512 MiB file bound")
            # Windows rename fails if destination exists, preserving existing media.
            if destination.exists():
                raise FileExistsError(str(destination))
            os.rename(temp, destination)
            temp = None
        digest = hashlib.sha256()
        with destination.open("rb") as f:
            for chunk in iter(lambda: f.read(1048576), b""):
                digest.update(chunk)
        return {"file": str(destination.resolve()), "sample_rate": 48000,
                "bits": 16, "channels": 1, "frames": frames,
                "duration_seconds": frames / 48000, "sha256": digest.hexdigest()}
    finally:
        if temp is not None:
            Path(temp).unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(convert(args.source, args.output_directory), ensure_ascii=False, indent=2))
