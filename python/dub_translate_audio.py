#!/usr/bin/env python3
"""
Create a dubbed MP3 by transcribing source audio, translating segments,
and generating TTS audio aligned to original timestamps.

Usage:
  python python/dub_translate_audio.py --in /path/audio.mp3 [--target-lang es] [--outdir DIR] [--out FILE]

Env:
  FWHISPER_MODEL: tiny|base|small|medium|large-v3 (default: base)
  FWHISPER_DEVICE: auto|cpu|cuda (default: auto)
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def _split_text_chunks(text: str, max_chars: int = 3500) -> list[str]:
    cleaned = " ".join(text.split())
    if len(cleaned) <= max_chars:
        return [cleaned]

    parts = re.split(r"(?<=[\.\!\?])\s+", cleaned)
    chunks: list[str] = []
    current = ""
    for part in parts:
        if not part:
            continue
        candidate = part if not current else f"{current} {part}"
        if len(candidate) <= max_chars:
            current = candidate
            continue
        if current:
            chunks.append(current)
        if len(part) <= max_chars:
            current = part
            continue
        for i in range(0, len(part), max_chars):
            chunks.append(part[i:i + max_chars])
        current = ""
    if current:
        chunks.append(current)
    return chunks


def _translate_text(text: str, translator) -> str:
    if translator is None:
        return text
    chunks = _split_text_chunks(text)
    out_parts: list[str] = []
    for chunk in chunks:
        if not chunk:
            continue
        try:
            translated = translator.translate(chunk)
            out_parts.append((translated or chunk).strip())
        except Exception as exc:  # noqa: BLE001
            print(
                f"[dub] Warning: translation failed for chunk ({exc}). Keeping original text.",
                file=sys.stderr,
            )
            out_parts.append(chunk)
    return " ".join(part for part in out_parts if part).strip()


def _merge_segments(segments, join_gap_s: float = 0.35, max_chars: int = 220, max_duration_s: float = 14.0):
    merged = []
    current = None

    for seg in segments:
        text = seg.text.strip()
        if not text:
            continue

        if current is None:
            current = {"start": float(seg.start), "end": float(seg.end), "text": text}
            continue

        gap = float(seg.start) - current["end"]
        candidate_text = f"{current['text']} {text}".strip()
        candidate_duration = float(seg.end) - current["start"]

        if gap <= join_gap_s and len(candidate_text) <= max_chars and candidate_duration <= max_duration_s:
            current["text"] = candidate_text
            current["end"] = float(seg.end)
        else:
            merged.append(current)
            current = {"start": float(seg.start), "end": float(seg.end), "text": text}

    if current is not None:
        merged.append(current)

    return merged


def _build_atempo_filter(speed: float) -> str:
    # ffmpeg atempo supports [0.5, 2.0] per filter; chain for larger factors.
    parts = []
    while speed > 2.0:
        parts.append("atempo=2.0")
        speed /= 2.0
    while speed < 0.5:
        parts.append("atempo=0.5")
        speed /= 0.5
    parts.append(f"atempo={speed:.6f}")
    return ",".join(parts)


def _fit_clip_to_slot(clip, slot_ms: int, tmpdir: str, idx: int):
    if slot_ms <= 0:
        return clip[:100]

    current_ms = len(clip)
    if current_ms <= slot_ms:
        return clip

    # Speed up only when necessary to avoid overlap between consecutive phrases.
    speed_factor = current_ms / float(slot_ms)
    if speed_factor < 1.02:
        return clip

    in_file = Path(tmpdir) / f"fit-in-{idx:05d}.wav"
    out_file = Path(tmpdir) / f"fit-out-{idx:05d}.wav"
    clip.export(str(in_file), format="wav")

    filter_chain = _build_atempo_filter(speed_factor)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(in_file),
        "-filter:a",
        filter_chain,
        str(out_file),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print(
            f"[dub] Warning: ffmpeg not found for tempo fit on segment {idx}. Trimming.",
            file=sys.stderr,
        )
        return clip[:slot_ms]
    if result.returncode != 0:
        print(
            f"[dub] Warning: tempo fit failed for segment {idx} ({result.stderr.strip()}). Trimming.",
            file=sys.stderr,
        )
        return clip[:slot_ms]

    try:
        from pydub import AudioSegment

        fitted = AudioSegment.from_file(str(out_file), format="wav")
        if len(fitted) > slot_ms:
            fitted = fitted[:slot_ms]
        return fitted
    except Exception as exc:  # noqa: BLE001
        print(f"[dub] Warning: failed to load fitted segment {idx} ({exc}). Trimming.", file=sys.stderr)
        return clip[:slot_ms]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--in", dest="input_path", required=True, help="Input audio/video file")
    p.add_argument("--target-lang", default="es", help="Target language code (default: es)")
    p.add_argument("--source-lang", default="auto", help="Source language code or 'auto' (default)")
    p.add_argument("--outdir", default="", help="Output directory (defaults next to input)")
    p.add_argument("--out", default="", help="Optional full output path")
    args = p.parse_args()

    in_path = Path(args.input_path)
    if not in_path.exists():
        print(f"ERROR: input not found: {in_path}", file=sys.stderr)
        sys.exit(2)

    target_lang = args.target_lang.strip()
    if not re.match(r"^[A-Za-z]{2}(?:-[A-Za-z]{2})?$", target_lang):
        print(f"ERROR: invalid target language code: {target_lang}", file=sys.stderr)
        sys.exit(2)
    translator_target_lang = target_lang.split("-")[0].lower()
    tts_lang = target_lang.lower()

    outdir = Path(args.outdir) if args.outdir else in_path.parent
    outdir.mkdir(parents=True, exist_ok=True)
    out_path = Path(args.out) if args.out else (outdir / f"{in_path.stem}_dub_{target_lang}.mp3")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Lazy imports for faster --help and clearer dependency errors.
    try:
        from deep_translator import GoogleTranslator
        from faster_whisper import WhisperModel
        from gtts import gTTS
        from pydub import AudioSegment
    except ImportError as exc:
        print(
            f"ERROR: missing dependency for dubbing ({exc}). Run: pip install -r requirements.txt",
            file=sys.stderr,
        )
        sys.exit(2)

    model_size = os.environ.get("FWHISPER_MODEL", "base")
    device_env = os.environ.get("FWHISPER_DEVICE", "auto")  # auto|cpu|cuda
    compute_type = "float16" if device_env == "cuda" else "int8"
    device = "cuda" if device_env == "cuda" else "auto"

    model = WhisperModel(model_size, device=device, compute_type=compute_type)
    src_lang = None if args.source_lang == "auto" else args.source_lang
    segments_iter, info = model.transcribe(str(in_path), language=src_lang, vad_filter=True)
    segments = list(segments_iter)

    if not segments:
        print("ERROR: no speech segments found to dub.", file=sys.stderr)
        sys.exit(1)

    merged_segments = _merge_segments(segments)
    if not merged_segments:
        print("ERROR: no valid merged segments found to dub.", file=sys.stderr)
        sys.exit(1)

    detected_lang = (info.language or args.source_lang or "auto")
    detected_base_lang = detected_lang.split("-")[0].lower()
    same_lang = detected_base_lang == translator_target_lang
    translator = None
    if not same_lang:
        src_for_translator = "auto" if detected_lang == "auto" else detected_lang
        translator = GoogleTranslator(source=src_for_translator, target=translator_target_lang)

    total_ms = int(max(seg["end"] for seg in merged_segments) * 1000) + 500
    canvas = AudioSegment.silent(duration=max(total_ms, 1000))

    tmpdir = tempfile.mkdtemp(prefix="dub_tts_")
    try:
        for idx, seg in enumerate(merged_segments, 1):
            text = seg["text"].strip()
            if not text:
                continue

            translated = _translate_text(text, translator)
            if not translated:
                continue

            tts_file = Path(tmpdir) / f"seg-{idx:05d}.mp3"
            try:
                tts = gTTS(text=translated, lang=tts_lang)
                tts.save(str(tts_file))
            except Exception as exc:  # noqa: BLE001
                print(f"ERROR: TTS failed for segment {idx}: {exc}", file=sys.stderr)
                sys.exit(1)

            clip = AudioSegment.from_file(str(tts_file), format="mp3")

            start_ms = max(0, int(seg["start"] * 1000))
            if idx < len(merged_segments):
                next_start_ms = max(start_ms + 250, int(merged_segments[idx]["start"] * 1000))
                slot_ms = max(250, next_start_ms - start_ms - 80)
            else:
                slot_ms = max(500, int((seg["end"] - seg["start"]) * 1000))

            clip = _fit_clip_to_slot(clip, slot_ms, tmpdir, idx)
            if len(clip) > slot_ms:
                clip = clip[:slot_ms]

            # Minimal fades to reduce abrupt phrase boundaries.
            if len(clip) > 120:
                clip = clip.fade_in(15).fade_out(60)

            end_ms = start_ms + len(clip)
            if end_ms > len(canvas):
                canvas += AudioSegment.silent(duration=(end_ms - len(canvas)))
            canvas = canvas.overlay(clip, position=start_ms)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    canvas.export(str(out_path), format="mp3", bitrate="192k")
    print(out_path)


if __name__ == "__main__":
    main()
