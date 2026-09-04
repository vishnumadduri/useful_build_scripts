# blender-mcp

Script to install Blender and [`uv`](https://docs.astral.sh/uv/), download the
[BlenderMCP addon](https://github.com/ahujasid/blender-mcp), and register the
`blender-mcp` MCP server with Claude Code so Claude can create/edit 3D assets
(models, materials, scenes) directly inside a running Blender session - useful
for game art, props, and general 3D asset generation.

BlenderMCP is two halves:

1. **A Blender addon** (`addon.py`) that runs a small socket server *inside*
   Blender on `localhost:9876`. It executes the Python/bpy commands Claude
   sends.
2. **An MCP server** (`uvx blender-mcp`) that Claude Code talks to over
   stdio, which relays to that socket.

This script installs Blender and `uv`, downloads the addon file, and wires up
half 2 automatically. Half 1 (installing/enabling the addon in Blender, and
clicking "Connect to Claude") is interactive and done inside the Blender UI -
see "Manual steps" below.

## Scripts

| Script | Purpose |
|---|---|
| `setup_blender_mcp_env.ps1` | Install Blender, uv, download the addon, and register the MCP server |
| `setup_blender_mcp_env.bat` | Double-clickable wrapper that runs the .ps1 with the execution policy bypassed |

---

## setup_blender_mcp_env.ps1

If your PowerShell execution policy blocks running local `.ps1` files (the
default on most Windows installs), either double-click
`setup_blender_mcp_env.bat` (or run it from `cmd.exe`, forwarding any
arguments), or run the `.ps1` directly with the policy bypassed for that one
process:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_blender_mcp_env.ps1 [args...]
```

`-ExecutionPolicy Bypass` only affects this one process - it does not change
your system-wide policy, so nothing else on the machine is weakened.

Otherwise, from a PowerShell prompt with a policy that already allows local
scripts (elevated recommended, since `winget install` may prompt for UAC):

```powershell
./setup_blender_mcp_env.ps1 [-SkipBlenderInstall] [-SkipUvInstall] [-SkipAddonDownload] [-SkipMcpRegister]
```

| Argument | Default | Description |
|---|---|---|
| `-SkipBlenderInstall` | off | Skip installing Blender (use if it's already installed) |
| `-SkipUvInstall` | off | Skip installing `uv` (use if it's already installed) |
| `-SkipAddonDownload` | off | Skip re-downloading `addon.py` |
| `-SkipMcpRegister` | off | Skip registering `blender-mcp` with Claude Code |

### What it does

1. Installs **Blender** via `winget` (`BlenderFoundation.Blender`)
2. Installs **uv** via `winget` (`astral-sh.uv`) - this provides `uvx`, which
   is how `blender-mcp` is normally run (`uvx blender-mcp`) without a
   separate pip install/venv
3. Downloads the BlenderMCP **addon** (`addon.py`) from the upstream repo to
   `%USERPROFILE%\.blender-mcp\addon.py`
4. Registers the MCP server with **Claude Code**:
   ```
   claude mcp add --scope user blender-mcp -- uvx --system-certs blender-mcp
   ```
   `--system-certs` makes `uv` trust the OS certificate store instead of its
   own bundled one - without it, `uvx blender-mcp` can fail to even fetch the
   package on networks with TLS-inspecting proxies (`invalid peer
   certificate: UnknownIssuer`).

Each step is best-effort and non-fatal: if `winget` or `claude` isn't
available, or a step fails, the script warns and continues so you can finish
that one step manually and re-run.

### Manual steps (cannot be scripted)

- **Install the addon in Blender** - open Blender, go to
  `Edit > Preferences > Add-ons`, use the dropdown in the top-right corner
  to `Install from Disk...`, and select
  `%USERPROFILE%\.blender-mcp\addon.py`. Enable the checkbox next to
  "Interface: Blender MCP".
- **Start the socket server** - in the 3D viewport, press `N` to open the
  sidebar, select the `BlenderMCP` tab, and click **Connect to Claude**.
  This must be repeated every time Blender is restarted - the server does
  not persist across sessions.
- **Optional integrations**, configured inside the same addon panel:
  - **Poly Haven** - toggle on to pull in free HDRIs/models/textures.
  - **Hyper3D Rodin** - add an API key to generate 3D models from text/images.
  - **Sketchfab** - add an API key/token to search and import Sketchfab models.
- **Verify the bridge** - in Claude Code, `claude mcp list` should show
  `blender-mcp`. With Blender open and connected, ask Claude to inspect or
  modify the scene; the first tool call launches `uvx blender-mcp` on demand.
- **Start a new Claude Code session after registering** - an already-running
  Claude Code session builds its tool list once at startup, so a server
  registered mid-conversation (e.g. by running this script from inside a
  session) shows as connected in `claude mcp list` but its tools (like
  `get_scene_info`, `execute_blender_code`) won't be available until you
  start a new session/conversation.

### Troubleshooting

- **"Could not connect to Blender"** - Blender must be open with the addon
  enabled *and* "Connect to Claude" clicked for the current session.
- **`uvx` not found** - open a new terminal so PATH picks up the winget
  install, or install uv manually:
  https://docs.astral.sh/uv/getting-started/installation/
- **`blender-mcp` shows "Failed to connect" / `CONNECTION_CLOSED` in
  `claude mcp list`** - almost always `uv`'s bundled TLS cert bundle failing
  on a network with a TLS-inspecting proxy (`invalid peer certificate:
  UnknownIssuer` if you run `uvx blender-mcp` by hand). This script already
  registers with `--system-certs` to avoid it; if you registered manually
  without that flag, re-run:
  `claude mcp add --scope user blender-mcp -- uvx --system-certs blender-mcp`
- **`winget install` fails with a cert error mentioning the `msstore`
  source** - same underlying TLS-inspection issue. Retry with
  `--source winget` appended, which is what this script now does.
- **Addon download fails** (e.g. no network access at script run time) -
  download `addon.py` manually from
  https://github.com/ahujasid/blender-mcp and install it from wherever you
  saved it.

### Examples

```powershell
# Full install with defaults
./setup_blender_mcp_env.ps1

# Blender and uv already installed - just re-download the addon and register MCP
./setup_blender_mcp_env.ps1 -SkipBlenderInstall -SkipUvInstall

# Everything already set up - just (re-)register with Claude Code
./setup_blender_mcp_env.ps1 -SkipBlenderInstall -SkipUvInstall -SkipAddonDownload
```
