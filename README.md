# Development Setup Scripts

A curated collection of setup helpers and reference notes for AI development,
robotics, media tooling, embedded simulation, and Linux video devices.

> Review a script and the linked documentation before running it. Several
> installers download software, modify shell configuration, or require `sudo`.

## Contents

| Area | What it includes |
| --- | --- |
| [`ai-setup/`](ai-setup/) | AI tooling, local-model benchmarking, ComfyUI, Blender MCP, Hunyuan3D, Ollama CUDA builds, and Unsloth installers |
| [`robotics/`](robotics/) | ROS 2 development setup and ROS 2 + Iceoryx 2 container files |
| [`renode/`](renode/) | Renode, Zephyr, and LVGL setup for STM32F746G-DISCO simulation |
| [`v4l2/`](v4l2/) | A practical `v4l2-ctl` command reference |

## Quick start on Linux or WSL

Use the dispatcher to see the Bash-based installers that are ready to run:

```bash
bash ./run-setup.sh list
```

Preview a command before execution:

```bash
bash ./run-setup.sh ros2 --dry-run -- jazzy desktop ~/ros2_ws
```

Then run it after reviewing its documentation:

```bash
bash ./run-setup.sh ros2 -- jazzy desktop ~/ros2_ws
```

The dispatcher only forwards arguments; it does not hide prompts, `sudo`, or
other effects of the selected installer. Windows-specific setup helpers live
alongside their respective `README.md` files and are generally PowerShell
scripts.

## Main documentation

- [Model benchmarking](ai-setup/benchmark/README.md)
- [Ollama CUDA 12.2 container](ai-setup/ollama-cuda12-container/README.md)
- [ROS 2](robotics/ros2-setup/README.md)
- [Zephyr + LVGL + Renode](renode/README.md)
- [Unsloth on Windows / AMD](ai-setup/unsloth-setup/README.md)
- [ComfyUI](ai-setup/media/comfyui-setup/README.md)
- [Blender MCP](ai-setup/media/blender-mcp/README.md)
- [V4L2 commands](v4l2/README.md)

## Requirements

- Bash scripts target Ubuntu/Debian or WSL unless their documentation says
  otherwise.
- PowerShell scripts target Windows.
- Individual setup guides specify required disk space, GPU drivers, SDKs, and
  external accounts or access tokens where applicable.
