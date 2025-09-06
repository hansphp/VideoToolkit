#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
cat <<USAGE
Uso:
  $(basename "$0") --in audio.mp3 [--format txt|srt|vtt|json] [--lang es|en|auto] [--outdir DIR]

Requiere: python3 + venv con dependencias (ver README).
Variables opcionales:
  FWHISPER_MODEL=tiny|base|small|medium|large-v3 (default: base)
  FWHISPER_DEVICE=auto|cpu|cuda (default: auto)
USAGE
}
IN=""; FMT="txt"; LANG="auto"; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="$2"; shift 2;;
    --format) FMT="$2"; shift 2;;
    --lang) LANG="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Opción desconocida: $1"; usage; exit 2;;
  esac
done

[[ -z "$IN" ]] && { echo "Falta --in"; usage; exit 2; }
OUTDIR="${OUTDIR:-"$(dirname "$IN")"}"

python3 "${ROOT_DIR}/python/transcribe_audio.py" --in "$IN" --format "$FMT" --lang "$LANG" --outdir "$OUTDIR"
