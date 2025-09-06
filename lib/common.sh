#!/usr/bin/env bash
set -euo pipefail

# Logging helpers
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERR] $*" >&2; }

# Check if a command exists in PATH
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Necesitas '$1' en PATH";
    exit 1;
  fi
}

# Extract audio to MP3 (320 kbps)
extract_audio() {
  local in="$1"; local out="$2";
  log "Extrayendo audio MP3 → $out"
  ffmpeg -y -i "$in" -vn -acodec libmp3lame -ar 44100 -b:a 320k "$out"
}

# Take screenshots at regular interval (seconds)
screenshots_interval() {
  local in="$1"; local outdir="$2"; local interval="$3"
  mkdir -p "$outdir"
  log "Capturas cada ${interval}s → $outdir"
  ffmpeg -y -i "$in" -vf fps=1/"$interval" -q:v 2 "$outdir"/shot-%04d.jpg
}

# Take screenshots based on FPS
screenshots_fps() {
  local in="$1"; local outdir="$2"; local fps="$3"
  mkdir -p "$outdir"
  log "Capturas a ${fps} fps → $outdir"
  ffmpeg -y -i "$in" -vf fps="$fps" -q:v 2 "$outdir"/shot-%04d.jpg
}

# Create speeded clip; optional trim; audio atempo chain
speed_clip() {
  local in="$1"; local out="$2"; local start="${3:-}"; local end="${4:-}"; local speed="${5:-2.0}"
  need bc
  # Build audio atempo chain (splitting >2.0 into 2.0* remainder)
  local remain="$speed"; local atempo_chain=""
  while (( $(echo "$remain > 2.0" | bc -l) )); do
    atempo_chain="${atempo_chain}atempo=2.0,"
    remain=$(echo "$remain/2.0" | bc -l)
  done
  atempo_chain="${atempo_chain}atempo=${remain}"
  # Build trim args only if provided
  local trim_args=()
  if [[ -n "$start" ]]; then trim_args+=("-ss" "$start"); fi
  if [[ -n "$end" ]]; then trim_args+=("-to" "$end"); fi
  log "Creando clip acelerado (${speed}x) ${start:-0} → ${end:-fin}"
  if (( ${#trim_args[@]} )); then
    ffmpeg -y "${trim_args[@]}" -i "$in" -filter_complex "[0:v]setpts=PTS/${speed}[v];[0:a]${atempo_chain}[a]" -map "[v]" -map "[a]" -movflags +faststart -preset veryfast -crf 23 "$out"
  else
    ffmpeg -y -i "$in" -filter_complex "[0:v]setpts=PTS/${speed}[v];[0:a]${atempo_chain}[a]" -map "[v]" -map "[a]" -movflags +faststart -preset veryfast -crf 23 "$out"
  fi
}
