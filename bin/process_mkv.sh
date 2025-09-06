#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"

usage() {
cat <<'USAGE'
Uso:
  process_mkv.sh --in INPUT.mkv [opciones]

Opciones (elige una o varias):
  --slides [method] [threshold]  Seleccionar 'diapositivas' únicas desde shots (method: phash|ssim|hist; threshold depende del método)
  --audio                      Extraer MP3 (320 kbps)
  --shots [N]                  Capturas cada N segundos (defecto 5)
  --fps [F]                    Capturas por FPS (p.e. 0.5 = una cada 2s)
  --clip [start] [end] [s]     Clip acelerado: inicio, fin, y factor (defecto 2.0). Tiempos HH:MM:SS
  --transcribe [fmt] [lang]    Transcribir el MP3 generado (fmt: txt|srt|vtt|json; lang: es|en|auto; defecto txt auto)
  --all                        Hacer todo (audio + shots cada 5s + clip 2x del video completo + transcribe txt auto)
  --outdir DIR                 Carpeta de salida (defecto ./out/<base>)
  -h|--help                    Mostrar ayuda

Ejemplos:
  process_mkv.sh --in clase.mkv --audio
  process_mkv.sh --in clase.mkv --shots 3
  process_mkv.sh --in clase.mkv --fps 0.5
  process_mkv.sh --in clase.mkv --clip 00:01:00 00:05:00 2.5
  process_mkv.sh --in clase.mkv --all
USAGE
}

IN=""; OUTDIR=""
DO_AUDIO=0
DO_SHOTS=0; SHOTS_N=5
DO_FPS=0; FPS_VAL=0.0
DO_CLIP=0; CLIP_S=""; CLIP_E=""; CLIP_SPEED="2.0"
DO_TRANS=0; T_FMT="txt"; T_LANG="auto"; DO_SLIDES=0; SL_METHOD="phash"; SL_THRESH=""
DO_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --audio) DO_AUDIO=1; shift;;
    --shots) DO_SHOTS=1; SHOTS_N="${2:-5}"; shift 2;;
    --fps) DO_FPS=1; FPS_VAL="${2:-0.5}"; shift 2;;
    --clip)
      DO_CLIP=1
      CLIP_S="${2:-}"; CLIP_E="${3:-}"; CLIP_SPEED="${4:-2.0}"
      if [[ $# -ge 4 ]]; then shift 4; else shift 1; fi
      ;;
    --transcribe)
      DO_TRANS=1
      T_FMT="${2:-txt}"; T_LANG="${3:-auto}"
      if [[ $# -ge 3 ]]; then shift 3; else shift 1; fi
      ;;
    --all) DO_ALL=1; shift;;
    --slides)
      DO_SLIDES=1
      SL_METHOD="${2:-phash}"; SL_THRESH="${3:-}"
      if [[ $# -ge 3 ]]; then shift 3; else shift 1; fi
      ;;
    -h|--help) usage; exit 0;;
    *) err "Opción desconocida: $1"; usage; exit 2;;
  esac
done

[[ -z "$IN" ]] && { err "Falta --in"; usage; exit 2; }
[[ ! -f "$IN" ]] && { err "No existe: $IN"; exit 2; }

base="$(basename "$IN")"
name="${base%.*}"
OUTDIR="${OUTDIR:-"${ROOT_DIR}/out/${name}"}"
mkdir -p "$OUTDIR"

if (( DO_ALL )); then
  DO_AUDIO=1; DO_SHOTS=1; SHOTS_N=5; DO_CLIP=1; CLIP_S=""; CLIP_E=""; CLIP_SPEED="2.0"; DO_TRANS=1; T_FMT="txt"; T_LANG="auto"
fi

if (( DO_AUDIO )); then
  extract_audio "$IN" "$OUTDIR/${name}.mp3"
fi

if (( DO_SHOTS )); then
  screenshots_interval "$IN" "$OUTDIR/shots" "$SHOTS_N"
fi

if (( DO_FPS )); then
  screenshots_fps "$IN" "$OUTDIR/shots_fps" "$FPS_VAL"
fi

if (( DO_SLIDES )); then
  SHOTS_DIR="$OUTDIR/shots"
  if [[ -d "$SHOTS_DIR" ]]; then
    log "Seleccionando diapositivas únicas → $OUTDIR/slides (método $SL_METHOD, umbral ${SL_THRESH:-auto})"
    if [[ -n "$SL_THRESH" ]]; then
      python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --method "$SL_METHOD" --threshold "$SL_THRESH"
    else
      python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --method "$SL_METHOD"
    fi
  else
    err "No existe el directorio de capturas: $SHOTS_DIR (usa --shots o --fps antes de --slides)"
  fi
fi

if (( DO_CLIP )); then
  speed_clip "$IN" "$OUTDIR/${name}_speed${CLIP_SPEED}.mp4" "${CLIP_S}" "${CLIP_E}" "${CLIP_SPEED}"
fi

if (( DO_TRANS )); then
  MP3_PATH="$OUTDIR/${name}.mp3"
  if [[ -f "$MP3_PATH" ]]; then
    log "Transcribiendo MP3 → formato ${T_FMT} idioma ${T_LANG}"
    python3 "${ROOT_DIR}/python/transcribe_audio.py" --in "$MP3_PATH" --format "$T_FMT" --lang "$T_LANG" --outdir "$OUTDIR"
  else
    err "No se encontró MP3 para transcribir: $MP3_PATH (usa --audio o --all)"
  fi
fi

log "Listo. Salida en: $OUTDIR"
