#!/bin/bash
# Model download script for LocalMind
# Usage: ./download_model.sh [model_url] [output_path]

set -e

DEFAULT_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
DEFAULT_OUTPUT_DIR="assets/models"

MODEL_URL="${1:-$DEFAULT_MODEL_URL}"
OUTPUT_DIR="${2:-$DEFAULT_OUTPUT_DIR}"

echo "========================================"
echo "LocalMind Model Downloader"
echo "========================================"
echo ""
echo "Model URL: $MODEL_URL"
echo "Output Dir: $OUTPUT_DIR"
echo ""

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Download the model
echo "Downloading model..."
curl -L -o "$OUTPUT_DIR/model.gguf" "$MODEL_URL"

# Check file size
FILE_SIZE=$(du -h "$OUTPUT_DIR/model.gguf" | cut -f1)
echo ""
echo "Download complete!"
echo "File size: $FILE_SIZE"
echo "Location: $OUTPUT_DIR/model.gguf"
echo ""
echo "To use this model in the app:"
echo "1. Open LocalMind"
echo "2. Go to Settings > Model Management"
echo "3. Select 'Load from Storage'"
echo "4. Navigate to $OUTPUT_DIR/model.gguf"
echo ""
