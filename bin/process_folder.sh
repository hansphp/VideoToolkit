#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"

usage() {
cat <<'USAGE'
Uso:
  process_folder.sh --indir DIR [opciones-del-lote] -- [opciones-de-process_mkv]

Procesa todos los archivos .mp4 y .mkv de una carpeta, uno por uno, reutilizando process_mkv.sh.

Opciones del lote:
  --indir DIR                 Carpeta con videos .mp4/.mkv (no recursivo)
  --outdir-root DIR           Carpeta raíz para las salidas del lote
  --continue-on-error         Continúa con el siguiente archivo si uno falla
  -h|--help                   Mostrar ayuda

Notas:
  - Las opciones después de -- se pasan tal cual a process_mkv.sh.
  - No pases --in ni --outdir después de --; este script los gestiona por archivo.

Ejemplos:
  process_folder.sh --indir input -- --shots 1 --slides ssim 0.20 --audio --transcribe txt en
  process_folder.sh --indir input --outdir-root ./out/lote -- --dub-video es
USAGE
}

INDIR=""
OUTDIR_ROOT=""
CONTINUE_ON_ERROR=0
PASSTHRU_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --indir)
      [[ $# -lt 2 || "$2" == -* ]] && { err "Falta valor para --indir"; usage; exit 2; }
      INDIR="$2"; shift 2;;
    --outdir-root)
      [[ $# -lt 2 || "$2" == -* ]] && { err "Falta valor para --outdir-root"; usage; exit 2; }
      OUTDIR_ROOT="$2"; shift 2;;
    --continue-on-error)
      CONTINUE_ON_ERROR=1; shift;;
    --)
      shift
      PASSTHRU_ARGS=("$@")
      break;;
    -h|--help)
      usage; exit 0;;
    *)
      err "Opción desconocida: $1"; usage; exit 2;;
  esac
done

[[ -z "$INDIR" ]] && { err "Falta --indir"; usage; exit 2; }
[[ ! -d "$INDIR" ]] && { err "No existe carpeta: $INDIR"; exit 2; }

for arg in "${PASSTHRU_ARGS[@]}"; do
  case "$arg" in
    --in|--outdir)
      err "No uses ${arg} después de --; process_folder.sh lo define por archivo."
      exit 2
      ;;
  esac
done

shopt -s nullglob nocaseglob
files=("$INDIR"/*.mp4 "$INDIR"/*.mkv)
shopt -u nullglob nocaseglob

if (( ${#files[@]} == 0 )); then
  err "No se encontraron archivos .mp4 o .mkv en: $INDIR"
  exit 1
fi

success_count=0
failure_count=0
total_count="${#files[@]}"
index=0

for video_path in "${files[@]}"; do
  index=$((index + 1))
  base="$(basename "$video_path")"
  name="${base%.*}"

  cmd=("${ROOT_DIR}/bin/process_mkv.sh" --in "$video_path")
  if [[ -n "$OUTDIR_ROOT" ]]; then
    cmd+=(--outdir "${OUTDIR_ROOT}/${name}")
  fi
  cmd+=("${PASSTHRU_ARGS[@]}")

  log "Procesando (${index}/${total_count}) → ${video_path}"
  if "${cmd[@]}"; then
    success_count=$((success_count + 1))
  else
    rc=$?
    failure_count=$((failure_count + 1))
    err "Falló ${video_path} con código ${rc}"
    if (( ! CONTINUE_ON_ERROR )); then
      exit "$rc"
    fi
  fi
done

log "Lote terminado. Exitosos: ${success_count}. Fallidos: ${failure_count}."
if (( failure_count > 0 )); then
  exit 1
fi
