#!/bin/bash
# Model downloader for LocalMind (desktop helper — the app can also download
# models itself from Settings -> Models).
#
# Downloads the GGUF models listed in lib/domain/models/local_model.dart.
#
# Usage:
#   ./download_model.sh              # list the catalog
#   ./download_model.sh qwen05b      # download Qwen2.5-0.5B-Instruct (default)
#   ./download_model.sh smollm2      # download SmolLM2-360M-Instruct
#   ./download_model.sh qwen15b      # download Qwen2.5-1.5B-Instruct
#   ./download_model.sh moondream2   # download Moondream2 vision + projector
#   ./download_model.sh all          # download everything
set -euo pipefail

OUT="assets/models"
HF="https://huggingface.co"

QWEN05B_NAME="qwen2.5-0.5b-instruct-q4_k_m.gguf"
QWEN05B_URL="$HF/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/$QWEN05B_NAME"

SMOLLM2_NAME="smollm2-360m-instruct-q8_0.gguf"
SMOLLM2_URL="$HF/HuggingFaceTB/SmolLM2-360M-Instruct-GGUF/resolve/main/$SMOLLM2_NAME"

QWEN15B_NAME="qwen2.5-1.5b-instruct-q4_k_m.gguf"
QWEN15B_URL="$HF/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/$QWEN15B_NAME"

MOON_NAME="moondream2-050824-q5k.gguf"
MOON_URL="$HF/cjpais/moondream2-llamafile/resolve/main/$MOON_NAME"
MOON_MMPROJ_NAME="moondream2-mmproj-050824-f16.gguf"
MOON_MMPROJ_URL="$HF/cjpais/moondream2-llamafile/resolve/main/$MOON_MMPROJ_NAME"

usage() {
  cat <<EOF
LocalMind model downloader

Usage: $0 [target]

Targets:
  qwen05b      Qwen2.5-0.5B-Instruct Q4_K_M   (~397 MB)  [default]
  smollm2      SmolLM2-360M-Instruct Q8_0     (~386 MB)
  qwen15b      Qwen2.5-1.5B-Instruct Q4_K_M   (~1.12 GB)
  moondream2   Moondream2 vision q5_k + mmproj (~1.6 GB total)
  all          everything above
  list         show this list

NOTE: Needle (Cactus) is NOT GGUF and cannot be used here — it requires the
Cactus native runtime instead of llama.cpp.
EOF
}

fetch() {
  local name="$1" url="$2"
  mkdir -p "$OUT"
  if [ -f "$OUT/$name" ] && [ "$(stat -c%s "$OUT/$name")" -gt 1048576 ]; then
    echo "  [skip] $name already present"
    return
  fi
  echo "  [get ] $name"
  # -C - resumes a partial file; curl handles redirects from HF.
  curl -L --fail --progress-bar -C - -o "$OUT/$name" "$url"
}

target="${1:-qwen05b}"

case "$target" in
  list|-h|--help|help) usage; exit 0 ;;
  qwen05b)   fetch "$QWEN05B_NAME" "$QWEN05B_URL" ;;
  smollm2)   fetch "$SMOLLM2_NAME" "$SMOLLM2_URL" ;;
  qwen15b)   fetch "$QWEN15B_NAME" "$QWEN15B_URL" ;;
  moondream2) fetch "$MOON_NAME" "$MOON_URL"; fetch "$MOON_MMPROJ_NAME" "$MOON_MMPROJ_URL" ;;
  all)
    fetch "$QWEN05B_NAME" "$QWEN05B_URL"
    fetch "$SMOLLM2_NAME" "$SMOLLM2_URL"
    fetch "$QWEN15B_NAME" "$QWEN15B_URL"
    fetch "$MOON_NAME" "$MOON_URL"
    fetch "$MOON_MMPROJ_NAME" "$MOON_MMPROJ_URL"
    ;;
  *) echo "Unknown target: $target"; echo; usage; exit 1 ;;
esac

echo
echo "Done. Files are in $OUT/"
du -h "$OUT"/*.gguf 2>/dev/null || true
echo
echo "In the app: Settings -> Models -> pick the model -> Load."
