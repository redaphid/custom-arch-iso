# Arch Linux AI-Powered Installer ISO

Create a bootable Arch Linux ISO with an AI assistant that guides you through the entire installation process using Ollama and fast-agent MCP framework.

## Features

- **Ollama Local LLM**: Runs Qwen2.5 7B model locally for offline AI assistance
- **Fast-Agent MCP Framework**: Provides interactive AI terminal interface
- **Pre-cached Dependencies**: All models and packages embedded in ISO for offline use
- **Auto-launch AI Assistant**: Boots directly into AI installation guide
- **Full System Access**: AI can execute installation commands directly

## Prerequisites

- Docker (with user in docker group or sudo access)
- ~20GB free disk space for cache and ISO
- Internet connection for initial download
- QEMU/KVM for testing (optional)

## Quick Start

1. **Download dependencies** (first time only):
   ```bash
   ./download-model.sh
   ```
   This caches Ollama binary, Qwen2.5 model, and Python/NPM packages to `tmp/`

2. **Build the ISO**:
   ```bash
   ./docker-build.sh
   ```
   Creates ISO in `isos/` directory with timestamp (e.g., `arch-ai-installer-20250925-033458.iso`)

3. **Test the ISO** (optional):
   ```bash
   ./test-iso.sh
   ```
   Automatically finds and boots the latest ISO in QEMU

## Directory Structure

```
.
├── docker-build.sh      # Main build script
├── download-model.sh    # Download and cache dependencies
├── test-iso.sh         # Test ISO in QEMU
├── tmp/                # Cached dependencies (gitignored)
│   ├── models/         # Ollama models
│   ├── ollama-binary/  # Ollama executable
│   ├── pip-cache/      # Python packages
│   └── npm-cache/      # NPM packages
├── isos/               # Built ISOs (gitignored)
└── CLAUDE.md          # Project documentation
```

## ISO Naming Convention

ISOs are named with ISO 8601 timestamp format:
```
arch-ai-installer-YYYYMMDD-HHMMSS.iso
```

Example: `arch-ai-installer-20250925-033458.iso`

## Usage

Once booted, the ISO will:
1. Auto-login as root
2. Start Ollama service with Qwen2.5 model
3. Launch fast-agent AI assistant
4. Present an interactive AI guide for Arch installation

The AI assistant can help with:
- Disk partitioning and formatting
- Base system installation
- Bootloader configuration
- Network setup
- User account creation
- Package installation
- System configuration

## SSH Access

Add your SSH key when building for remote access:
```bash
./docker-build.sh "$(cat ~/.ssh/id_rsa.pub)"
```

## Troubleshooting

If the build fails:
- Ensure Docker is running and accessible
- Check available disk space (needs ~20GB)
- Verify tmp/ cache directory exists after running download-model.sh
- Check Docker logs if ISO generation fails

## Technical Details

- **Base**: Arch Linux live environment with archiso
- **LLM Runtime**: Ollama serving Qwen2.5 7B model
- **Interface**: fast-agent-mcp Python package
- **MCP Servers**: filesystem and fetch for system access
- **Size**: ~1.7GB ISO with embedded models