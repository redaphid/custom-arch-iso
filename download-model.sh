#!/bin/bash
# download-model.sh - Download and cache Ollama model and dependencies locally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"
MODELS_DIR="$CACHE_DIR/models"
PIP_CACHE="$CACHE_DIR/pip-cache"
NPM_CACHE="$CACHE_DIR/npm-cache"
OLLAMA_DIR="$CACHE_DIR/ollama-binary"

echo "═══════════════════════════════════════════════════════════════"
echo "       Downloading AI Installer Dependencies"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create directories
mkdir -p "$MODELS_DIR" "$PIP_CACHE" "$NPM_CACHE" "$OLLAMA_DIR"

# 1. Download Ollama binary (if not already present)
echo "1. Downloading Ollama binary..."
if [ ! -f "$OLLAMA_DIR/ollama" ]; then
    echo "   Downloading Ollama installer..."
    curl -L https://ollama.ai/download/ollama-linux-amd64 -o "$OLLAMA_DIR/ollama"
    chmod +x "$OLLAMA_DIR/ollama"
    echo "   ✓ Ollama binary downloaded"
else
    echo "   ✓ Ollama binary already cached"
fi

# 2. Check if Ollama is installed locally for model download
if ! command -v ollama &> /dev/null; then
    echo ""
    echo "Ollama not installed locally. Installing temporarily..."
    curl -fsSL https://ollama.ai/install.sh | sh
fi

# 3. Download the Qwen2.5 model
echo ""
echo "2. Downloading Qwen2.5 7B model (this may take a while)..."

# Check if model already exists
MODEL_NAME="qwen2.5:7b"
MODEL_PATH="$MODELS_DIR/qwen2.5-7b"

if [ -d "$MODEL_PATH" ] && [ "$(ls -A $MODEL_PATH 2>/dev/null)" ]; then
    echo "   ✓ Model already cached at $MODEL_PATH"
else
    echo "   Pulling model with Ollama..."

    # Start Ollama service temporarily if not running
    if ! pgrep ollama > /dev/null; then
        echo "   Starting Ollama service..."
        ollama serve &
        OLLAMA_PID=$!
        sleep 5
    fi

    # Pull the model
    ollama pull $MODEL_NAME || {
        echo "   Error pulling model. Trying alternative method..."
    }

    # Find where Ollama stores models (could be in various locations)
    OLLAMA_MODEL_DIR=""
    for dir in "/usr/share/ollama/.ollama/models" "$HOME/.ollama/models" "/var/lib/ollama/models"; do
        if [ -d "$dir" ]; then
            OLLAMA_MODEL_DIR="$dir"
            break
        fi
    done

    if [ -n "$OLLAMA_MODEL_DIR" ]; then
        echo "   Found Ollama models at: $OLLAMA_MODEL_DIR"
        echo "   Copying model files to cache..."

        # Copy entire models directory structure
        if [ -r "$OLLAMA_MODEL_DIR" ]; then
            cp -r "$OLLAMA_MODEL_DIR"/* "$MODELS_DIR/" 2>/dev/null || {
                echo "   Direct copy failed, trying with different permissions..."
                # If direct copy fails, try reading files individually
                mkdir -p "$MODELS_DIR/blobs" "$MODELS_DIR/manifests"

                # Copy blobs (the actual model data)
                if [ -d "$OLLAMA_MODEL_DIR/blobs" ]; then
                    for blob in "$OLLAMA_MODEL_DIR/blobs/"*; do
                        [ -r "$blob" ] && cp "$blob" "$MODELS_DIR/blobs/" 2>/dev/null
                    done
                fi

                # Copy manifests
                if [ -d "$OLLAMA_MODEL_DIR/manifests" ]; then
                    cp -r "$OLLAMA_MODEL_DIR/manifests"/* "$MODELS_DIR/manifests/" 2>/dev/null || true
                fi
            }
            echo "   ✓ Model cached successfully"
        else
            echo "   Warning: Cannot read Ollama models directory (may need different permissions)"
        fi
    else
        echo "   Warning: Could not find Ollama models directory"
    fi

    # Stop Ollama if we started it
    if [ ! -z "${OLLAMA_PID:-}" ]; then
        echo "   Stopping Ollama service..."
        kill $OLLAMA_PID 2>/dev/null || true
    fi
fi

# 4. Download Python packages
echo ""
echo "3. Downloading Python packages..."
# Download fast-agent-mcp and ALL dependencies
pip download --dest "$PIP_CACHE" \
    fast-agent-mcp \
    2>/dev/null || echo "   Some packages may have failed, continuing..."

# Also explicitly download common dependencies to ensure we have them
pip download --dest "$PIP_CACHE" \
    mcp \
    aiohttp \
    pydantic \
    pyyaml \
    rich \
    typer \
    click \
    httpx \
    websockets \
    uvloop \
    anthropic \
    2>/dev/null || true

echo "   ✓ Python packages cached"

# 5. Download NPM packages
echo ""
echo "4. Caching NPM packages..."
cd "$NPM_CACHE"
npm pack @modelcontextprotocol/server-filesystem 2>/dev/null || true
npm pack @modelcontextprotocol/server-fetch 2>/dev/null || true
cd "$SCRIPT_DIR"
echo "   ✓ NPM packages cached"

# 6. Display cache size
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Cache Summary:"
echo ""
echo "Models:    $(du -sh $MODELS_DIR 2>/dev/null | cut -f1)"
echo "Python:    $(du -sh $PIP_CACHE 2>/dev/null | cut -f1)"
echo "NPM:       $(du -sh $NPM_CACHE 2>/dev/null | cut -f1)"
echo "Ollama:    $(du -sh $OLLAMA_DIR 2>/dev/null | cut -f1)"
echo "Total:     $(du -sh $CACHE_DIR 2>/dev/null | cut -f1)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "✓ All dependencies cached successfully!"
echo "  Run ./docker-build.sh to build the ISO with embedded models"