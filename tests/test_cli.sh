#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
export TEST_PYTHON3_LOG="$TMP_ROOT/python3_calls.log"
: > "$TEST_PYTHON3_LOG"

cat > "$FAKE_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
mkdir -p "$(dirname "$out")"
if [[ "$out" == *"%04d"* ]]; then
  shot="${out//%04d/0001}"
  : > "$shot"
else
  : > "$out"
fi
EOF

cat > "$FAKE_BIN/yt-dlp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out_template=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out_template="$2"; shift 2;;
    *) shift;;
  esac
done
[[ -z "$out_template" ]] && exit 2
target="${out_template//%(id)s/testid}"
target="${target//%(ext)s/mp4}"
mkdir -p "$(dirname "$target")"
: > "$target"
EOF

cat > "$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
echo "$script $*" >> "$TEST_PYTHON3_LOG"

if [[ "$script" == *"select_slides.py" ]]; then
  outdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --outdir) outdir="$2"; shift 2;;
      *) shift;;
    esac
  done
  [[ -n "$outdir" ]] && mkdir -p "$outdir"
elif [[ "$script" == *"transcribe_audio.py" ]]; then
  in_path=""
  outdir=""
  fmt="txt"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in_path="$2"; shift 2;;
      --outdir) outdir="$2"; shift 2;;
      --format) fmt="$2"; shift 2;;
      *) shift;;
    esac
  done
  if [[ -n "$in_path" && -n "$outdir" ]]; then
    base="$(basename "$in_path")"
    base="${base%.*}"
    mkdir -p "$outdir"
    : > "$outdir/$base.$fmt"
  fi
fi
EOF

cat > "$FAKE_BIN/bc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expr="$(cat)"
[[ -z "$expr" ]] && expr="0"
awk "BEGIN { print ($expr) }"
EOF

chmod +x "$FAKE_BIN/ffmpeg" "$FAKE_BIN/yt-dlp" "$FAKE_BIN/python3" "$FAKE_BIN/bc"
export PATH="$FAKE_BIN:$PATH"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect_success() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name}.log"
  if ! "$@" >"$log" 2>&1; then
    sed -n '1,120p' "$log" >&2
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name}.log"
  if "$@" >"$log" 2>&1; then
    sed -n '1,120p' "$log" >&2
    fail "$name (expected failure)"
  fi
}

INPUT="$TMP_ROOT/input.mp4"
: > "$INPUT"

expect_success mkv_clip_single_arg \
  "$ROOT_DIR/bin/process_mkv.sh" --in "$INPUT" --clip 00:00:01 --outdir "$TMP_ROOT/out-mkv-clip"
[[ -f "$TMP_ROOT/out-mkv-clip/input_speed2.0.mp4" ]] || fail "mkv clip output missing"

expect_success mkv_fps_slides \
  "$ROOT_DIR/bin/process_mkv.sh" --in "$INPUT" --fps 0.2 --slides ssim 0.2 --outdir "$TMP_ROOT/out-mkv-fps-slides"
grep -F -- "--in $TMP_ROOT/out-mkv-fps-slides/shots_fps" "$TEST_PYTHON3_LOG" >/dev/null || fail "mkv slides did not use shots_fps"

expect_failure mkv_transcribe_without_audio \
  "$ROOT_DIR/bin/process_mkv.sh" --in "$INPUT" --transcribe --outdir "$TMP_ROOT/out-mkv-transcribe-fail"

expect_failure mkv_slides_without_captures \
  "$ROOT_DIR/bin/process_mkv.sh" --in "$INPUT" --slides --outdir "$TMP_ROOT/out-mkv-slides-fail"

expect_success mkv_defaults_optional_args \
  "$ROOT_DIR/bin/process_mkv.sh" --in "$INPUT" --shots --slides --audio --transcribe --outdir "$TMP_ROOT/out-mkv-defaults"
grep -F -- "--format txt --lang auto" "$TEST_PYTHON3_LOG" >/dev/null || fail "mkv transcribe defaults were not applied"

expect_success yt_clip_single_arg \
  "$ROOT_DIR/bin/process_youtube.sh" --url "https://youtube.com/watch?v=test" --clip 00:00:01 --outdir "$TMP_ROOT/out-yt-clip"
[[ -f "$TMP_ROOT/out-yt-clip/testid_speed2.0.mp4" ]] || fail "youtube clip output missing"

expect_success yt_fps_slides \
  "$ROOT_DIR/bin/process_youtube.sh" --url "https://youtube.com/watch?v=test" --fps 0.2 --slides ssim 0.2 --outdir "$TMP_ROOT/out-yt-fps-slides"
grep -F -- "--in $TMP_ROOT/out-yt-fps-slides/shots_fps" "$TEST_PYTHON3_LOG" >/dev/null || fail "youtube slides did not use shots_fps"

expect_failure yt_transcribe_without_audio \
  "$ROOT_DIR/bin/process_youtube.sh" --url "https://youtube.com/watch?v=test" --transcribe --outdir "$TMP_ROOT/out-yt-transcribe-fail"

echo "All CLI tests passed."
