# AI-Assisted Arch Linux Installer ISO

## Project Goal
Create a bootable Arch Linux ISO that boots directly into an AI-powered installation assistant using fast-agent with ollama and a local LLM (GPT-OSS/Qwen), providing an interactive AI interface to guide and execute the entire Arch Linux installation process.

## Key Components
1. **Ollama** - Local LLM runtime for offline AI capabilities
2. **Fast-Agent MCP** - Modern agent framework for AI interactions
3. **GPT-OSS/Qwen Model** - Efficient open-source model optimized for 4090
4. **MCP Servers** - Filesystem and fetch capabilities for system manipulation
5. **Auto-launch** - Boot directly into fast-agent interactive mode

## Architecture
- Base: Arch Linux Live ISO with essential tools
- AI Layer: Ollama service running Qwen/GPT-OSS model
- Interface: Fast-agent providing interactive terminal AI assistant
- Capabilities: Full filesystem access, network fetch, system commands
- Purpose: Guide user through partitioning, formatting, base system install, bootloader, and configuration

## Installation Flow
1. Boot from ISO → Auto-start ollama service
2. Load optimized LLM model
3. Launch fast-agent with system-wide MCP permissions
4. AI assistant greets user and offers installation guidance
5. Interactive installation with AI executing commands
6. Complete system configuration with AI assistance

## Technical Requirements
- Ollama configured for optimal 4090 performance
- Fast-agent with unrestricted filesystem access
- Network connectivity for package downloads
- Pre-configured MCP servers for system operations
- Auto-start systemd services
- TTY allocation for interactive mode

## Benefits
- Intelligent, context-aware installation guidance
- AI can directly execute installation commands
- Natural language interaction for complex configurations
- Offline-capable with local LLM
- Customizable installation paths
- Real-time problem solving during installation