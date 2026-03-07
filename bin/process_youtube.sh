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

is_number() {
  [[ "${1:-}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

is_positive_number() {
  is_number "$1" && awk "BEGIN { exit !($1 > 0) }"
}

is_non_negative_number() {
  is_number "$1" && awk "BEGIN { exit !($1 >= 0) }"
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
    --url)
      [[ $# -lt 2 || "$2" == -* ]] && { err "Falta valor para --url"; usage; exit 2; }
      URL="$2"; shift 2;;
    --outdir)
      [[ $# -lt 2 || "$2" == -* ]] && { err "Falta valor para --outdir"; usage; exit 2; }
      OUTDIR="$2"; shift 2;;
    --audio) DO_AUDIO=1; shift;;
    --shots)
      DO_SHOTS=1
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then
        SHOTS_N="$1"; shift
      fi
      ;;
    --fps)
      DO_FPS=1
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then
        FPS_VAL="$1"; shift
      fi
      ;;
    --clip)
      DO_CLIP=1
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then CLIP_S="$1"; shift; fi
      if [[ $# -gt 0 && "$1" != -* ]]; then CLIP_E="$1"; shift; fi
      if [[ $# -gt 0 && "$1" != -* ]]; then CLIP_SPEED="$1"; shift; fi
      ;;
    --transcribe)
      DO_TRANS=1
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then T_FMT="$1"; shift; fi
      if [[ $# -gt 0 && "$1" != -* ]]; then T_LANG="$1"; shift; fi
      ;;
    --all) DO_ALL=1; shift;;
    --slides)
      DO_SLIDES=1
      shift
      if [[ $# -gt 0 && "$1" != -* ]]; then SL_METHOD="$1"; shift; fi
      if [[ $# -gt 0 && "$1" != -* ]]; then SL_THRESH="$1"; shift; fi
      ;;
    -h|--help) usage; exit 0;;
    *) err "Opción desconocida: $1"; usage; exit 2;;
  esac
done

[[ -z "$URL" ]] && { err "Falta --url"; usage; exit 2; }
if (( DO_SHOTS )); then
  if ! [[ "$SHOTS_N" =~ ^[0-9]+$ ]] || (( SHOTS_N <= 0 )); then
    err "--shots requiere un entero > 0 (recibido: $SHOTS_N)"; exit 2
  fi
fi
if (( DO_FPS )) && ! is_positive_number "$FPS_VAL"; then
  err "--fps requiere un número > 0 (recibido: $FPS_VAL)"; exit 2
fi
if (( DO_CLIP )) && ! is_positive_number "$CLIP_SPEED"; then
  err "--clip velocidad requiere un número > 0 (recibido: $CLIP_SPEED)"; exit 2
fi
if (( DO_SLIDES )); then
  case "$SL_METHOD" in
    phash|ssim|hist) ;;
    *) err "--slides método inválido: $SL_METHOD (usa phash|ssim|hist)"; exit 2;;
  esac
  if [[ -n "$SL_THRESH" ]] && ! is_non_negative_number "$SL_THRESH"; then
    err "--slides threshold debe ser numérico y >= 0 (recibido: $SL_THRESH)"; exit 2
  fi
fi
if (( DO_TRANS )); then
  case "$T_FMT" in
    txt|srt|vtt|json) ;;
    *) err "--transcribe formato inválido: $T_FMT (usa txt|srt|vtt|json)"; exit 2;;
  esac
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

log "Descargando video…"
YTDLP_FORMAT='bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b'
YTDLP_EXTRACTOR_ARGS="${YTDLP_EXTRACTOR_ARGS:-youtube:player_client=android,ios,tv}"
YTDLP_COOKIES_FROM_BROWSER="${YTDLP_COOKIES_FROM_BROWSER:-}"

YT_CMD=(
  yt-dlp
  --extractor-args "$YTDLP_EXTRACTOR_ARGS"
  --retries 10
  --fragment-retries 10
  --extractor-retries 3
  --socket-timeout 15
  -f "$YTDLP_FORMAT"
  -o "${TMPDIR}/%(id)s.%(ext)s"
)

if [[ -n "$YTDLP_COOKIES_FROM_BROWSER" ]]; then
  YT_CMD+=(--cookies-from-browser "$YTDLP_COOKIES_FROM_BROWSER")
fi

"${YT_CMD[@]}" "$URL"
shopt -s nullglob
mp4_files=("${TMPDIR}"/*.mp4)
shopt -u nullglob
if (( ${#mp4_files[@]} > 0 )); then
  DL_FILE="${mp4_files[0]}"
else
  shopt -s nullglob
  any_files=("${TMPDIR}"/*)
  shopt -u nullglob
  if (( ${#any_files[@]} == 0 )); then
    err "yt-dlp no descargó archivos para: $URL"
    exit 1
  fi
  ANY_FILE="${any_files[0]}"
  DL_FILE="${TMPDIR}/video.mp4"
  log "Convirtiendo a MP4 → ${DL_FILE}"
  need ffmpeg
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

if (( DO_SLIDES || DO_TRANS )); then
  need python3
fi

CAPTURE_DIR=""
if (( DO_AUDIO )); then
  extract_audio "$IN" "$OUTDIR/${VID_ID}.mp3"
fi
if (( DO_SHOTS )); then
  screenshots_interval "$IN" "$OUTDIR/shots" "$SHOTS_N"
  CAPTURE_DIR="$OUTDIR/shots"
fi
if (( DO_FPS )); then
  screenshots_fps "$IN" "$OUTDIR/shots_fps" "$FPS_VAL"
  if [[ -z "$CAPTURE_DIR" ]]; then
    CAPTURE_DIR="$OUTDIR/shots_fps"
  fi
fi

if (( DO_SLIDES )); then
  SHOTS_DIR="$CAPTURE_DIR"
  if [[ -z "$SHOTS_DIR" ]]; then
    if [[ -d "$OUTDIR/shots" ]]; then
      SHOTS_DIR="$OUTDIR/shots"
    elif [[ -d "$OUTDIR/shots_fps" ]]; then
      SHOTS_DIR="$OUTDIR/shots_fps"
    fi
  fi
  if [[ -z "$SHOTS_DIR" || ! -d "$SHOTS_DIR" ]]; then
    err "No existe directorio de capturas para --slides (genera con --shots o --fps)"
    exit 1
  fi

  log "Seleccionando diapositivas únicas → $OUTDIR/slides (método $SL_METHOD, umbral ${SL_THRESH:-auto})"
  if [[ -n "$SL_THRESH" ]]; then
    python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --min-words 2 --ocr-lang "eng+spa" --method "$SL_METHOD" --threshold "$SL_THRESH"
  else
    python3 "${ROOT_DIR}/python/select_slides.py" --in "$SHOTS_DIR" --outdir "$OUTDIR/slides" --min-words 2 --ocr-lang "eng+spa" --method "$SL_METHOD"
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
    exit 1
  fi
fi

log "Listo. Salida en: $OUTDIR"
