#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"

need yt-dlp

usage() {
cat <<'USAGE'
Uso:
  process_youtube.sh --url "https://youtube.com/..." [opciones]

Descarga el video con yt-dlp (mejor MP4 posible) y aplica los mismos pasos que process_mkv.sh.

Opciones (idénticas):
  --slides [method] [threshold]  Seleccionar 'diapositivas' únicas desde shots (method: phash|ssim|hist; threshold depende del método)
  --audio                      Extraer MP3
  --shots [N]                  Capturas cada N segundos (defecto 5)
  --fps [F]                    Capturas por FPS (p.e. 0.5)
  --clip [start] [end] [s]     Clip acelerado: inicio, fin, factor (defecto 2.0)
  --transcribe [fmt] [lang]    Transcribir el MP3 generado (fmt: txt|srt|vtt|json; lang: es|en|auto; defecto txt auto)
  --all                        Todo (audio + shots 5s + clip 2x + transcribe txt auto)
  --outdir DIR                 Carpeta de salida base (defecto ./out/youtube/<video_id>)
  -h|--help                    Ayuda

Ejemplos:
  process_youtube.sh --url "https://www.youtube.com/watch?v=abc" --all
  process_youtube.sh --url "https://www.youtube.com/watch?v=abc" --audio --shots 3
USAGE
}

URL=""; OUTDIR=""
DO_AUDIO=0
DO_SHOTS=0; SHOTS_N=5
DO_FPS=0; FPS_VAL=0.0
DO_CLIP=0; CLIP_S=""; CLIP_E=""; CLIP_SPEED="2.0"
DO_TRANS=0; T_FMT="txt"; T_LANG="auto"; DO_SLIDES=0; SL_METHOD="phash"; SL_THRESH=""
DO_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2;;
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

[[ -z "$URL" ]] && { err "Falta --url"; usage; exit 2; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

log "Descargando video…"
yt-dlp -f "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b" -o "${TMPDIR}/%(id)s.%(ext)s" "$URL"
DL_FILE="$(ls -1 ${TMPDIR}/*.mp4 2>/dev/null | head -n1 || true)"
if [[ -z "${DL_FILE}" ]]; then
  ANY_FILE="$(ls -1 ${TMPDIR}/* | head -n1)"
  DL_FILE="${TMPDIR}/video.mp4"
  log "Convirtiendo a MP4 → ${DL_FILE}"
  ffmpeg -y -i "$ANY_FILE" -c:v libx264 -c:a aac -movflags +faststart "$DL_FILE"
fi

VID_ID="$(basename "$DL_FILE")"
VID_ID="${VID_ID%.*}"

OUTDIR="${OUTDIR:-"${ROOT_DIR}/out/youtube/${VID_ID}"}"
mkdir -p "$OUTDIR"
cp "$DL_FILE" "$OUTDIR/${VID_ID}.mp4"
IN="$OUTDIR/${VID_ID}.mp4"

if (( DO_ALL )); then
  DO_AUDIO=1; DO_SHOTS=1; SHOTS_N=5; DO_CLIP=1; CLIP_S=""; CLIP_E=""; CLIP_SPEED="2.0"; DO_TRANS=1; T_FMT="txt"; T_LANG="auto"
fi

if (( DO_AUDIO )); then
  extract_audio "$IN" "$OUTDIR/${VID_ID}.mp3"
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
      python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --min-words 2 --ocr-lang "eng+spa" --method "$SL_METHOD" --threshold "$SL_THRESH"
    else
      python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --min-words 2 --ocr-lang "eng+spa" --method "$SL_METHOD"
    fi
  else
    err "No existe el directorio de capturas: $SHOTS_DIR (usa --shots o --fps antes de --slides)"
  fi
fi
if (( DO_CLIP )); then
  speed_clip "$IN" "$OUTDIR/${VID_ID}_speed${CLIP_SPEED}.mp4" "${CLIP_S}" "${CLIP_E}" "${CLIP_SPEED}"
fi

if (( DO_TRANS )); then
  MP3_PATH="$OUTDIR/${VID_ID}.mp3"
  if [[ -f "$MP3_PATH" ]]; then
    log "Transcribiendo MP3 → formato ${T_FMT} idioma ${T_LANG}"
    python3 "${ROOT_DIR}/python/transcribe_audio.py" --in "$MP3_PATH" --format "$T_FMT" --lang "$T_LANG" --outdir "$OUTDIR"
  else
    err "No se encontró MP3 para transcribir: $MP3_PATH (usa --audio o --all)"
  fi
fi

log "Listo. Salida en: $OUTDIR"
