#!/usr/bin/env python3
"""
Transcribe an MP3 (or any audio/video readable by ffmpeg) using faster-whisper.

Usage:
  python/python/transcribe_audio.py --in /path/audio.mp3 [--format txt|srt|vtt|json] [--lang es|en|auto] [--outdir DIR]

Env:
  FWHISPER_MODEL: tiny|base|small|medium|large-v3 (default: base)
  FWHISPER_DEVICE: auto|cpu|cuda (default: auto)
"""
import argparse, os, sys, json
from pathlib import Path

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--in", dest="input_path", required=True, help="Input audio/video file (e.g., MP3)")
    p.add_argument("--format", dest="fmt", default="txt", choices=["txt","srt","vtt","json"], help="Output format")
    p.add_argument("--lang", dest="lang", default="auto", help="Language code or 'auto'")
    p.add_argument("--outdir", dest="outdir", default="", help="Output directory (defaults next to input)")
    args = p.parse_args()

    in_path = Path(args.input_path)
    if not in_path.exists():
        print(f"ERROR: input not found: {in_path}", file=sys.stderr)
        sys.exit(2)

    outdir = Path(args.outdir) if args.outdir else in_path.parent
    outdir.mkdir(parents=True, exist_ok=True)

    # Lazy import to speed --help
    from faster_whisper import WhisperModel

    model_size = os.environ.get("FWHISPER_MODEL", "base")
    device_env = os.environ.get("FWHISPER_DEVICE", "auto")  # auto|cpu|cuda
    compute_type = "float16" if device_env == "cuda" else "int8"
    device = "cuda" if device_env == "cuda" else "auto"

    model = WhisperModel(model_size, device=device, compute_type=compute_type)

    # language None = auto-detect
    language = None if args.lang == "auto" else args.lang

    segments, info = model.transcribe(str(in_path), language=language, vad_filter=True)

    base = in_path.stem
    if args.fmt == "txt":
        out = outdir / f"{base}.txt"
        with open(out, "w", encoding="utf-8") as f:
            for seg in segments:
                f.write(seg.text.strip()+"\n")
        print(out)
    elif args.fmt == "srt":
        out = outdir / f"{base}.srt"
        with open(out, "w", encoding="utf-8") as f:
            for i, seg in enumerate(segments, 1):
                start = srt_ts(seg.start)
                end = srt_ts(seg.end)
                f.write(f"{i}\n{start} --> {end}\n{seg.text.strip()}\n\n")
        print(out)
    elif args.fmt == "vtt":
        out = outdir / f"{base}.vtt"
        with open(out, "w", encoding="utf-8") as f:
            f.write("WEBVTT\n\n")
            for seg in segments:
                start = srt_ts(seg.start, vtt=True)
                end = srt_ts(seg.end, vtt=True)
                f.write(f"{start} --> {end}\n{seg.text.strip()}\n\n")
        print(out)
    else:  # json
        out = outdir / f"{base}.json"
        out_data = {
            "language": info.language,
            "duration": info.duration,
            "segments": [
                {"start": s, "end": e, "text": t}
                for (s, e, t) in ((seg.start, seg.end, seg.text.strip()) for seg in segments)
            ],
        }
        with open(out, "w", encoding="utf-8") as f:
            json.dump(out_data, f, ensure_ascii=False, indent=2)
        print(out)

def srt_ts(seconds: float, vtt: bool=False) -> str:
    ms = int((seconds - int(seconds)) * 1000)
    s = int(seconds) % 60
    m = int(seconds // 60) % 60
    h = int(seconds // 3600)
    if vtt:
        return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

if __name__ == "__main__":
    main()
