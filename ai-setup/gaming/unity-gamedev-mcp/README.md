# unity-gamedev-mcp

Script to install Unity Hub, VS Code, and a Unity 6 Editor on Windows, create a starter
Unity project, and wire that project up to Unity's first-party
[MCP server](https://docs.unity3d.com/Packages/com.unity.ai.assistant@2.18/manual/integration/unity-mcp-get-started.html)
(the relay shipped with the built-in `com.unity.ai.assistant` package) so both VS Code
and Claude Code can drive the Unity Editor over MCP.

> **Note:** Unity's own docs currently mark this MCP server as deprecated in favor of a
> newer [Unity CLI](https://docs.unity.com/en-us/unity-cli). That CLI isn't documented
> in enough detail yet to script against, so this setup targets the MCP relay for now -
> revisit it once the CLI path is documented.

## Scripts

| Script | Purpose |
|---|---|
| `setup_unity_gamedev_env.ps1` | Install Unity Hub, VS Code, a Unity 6 Editor, a project, and MCP config |
| `setup_unity_gamedev_env.bat` | Double-clickable wrapper that runs the .ps1 with the execution policy bypassed |

---

## setup_unity_gamedev_env.ps1

If your PowerShell execution policy blocks running local `.ps1` files (the default on
most Windows installs), either double-click `setup_unity_gamedev_env.bat` (or run it
from `cmd.exe`, forwarding any arguments), or run the `.ps1` directly with the policy
bypassed for that one process:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_unity_gamedev_env.ps1 [args...]
```

`-ExecutionPolicy Bypass` only affects this one process - it does not change your
system-wide policy, so nothing else on the machine is weakened.

Otherwise, from a PowerShell prompt with a policy that already allows local scripts
(elevated recommended, since `winget install` may prompt for UAC):

```powershell
./setup_unity_gamedev_env.ps1 [-ProjectName <name>] [-ProjectsRoot <dir>] `
    [-SkipEditorInstall] [-SkipProjectCreate] [-SkipMcpRegister] [-SkipVSCodeExtensions]
```

| Argument | Default | Description |
|---|---|---|
| `-ProjectName` | `MyUnityGame` | Name of the Unity project to create |
| `-ProjectsRoot` | `~\UnityProjects` | Parent directory for the project |
| `-SkipEditorInstall` | off | Skip the Unity Editor install (use if one is already installed) |
| `-SkipProjectCreate` | off | Skip project creation (use if the project already exists at `ProjectsRoot\ProjectName`) |
| `-SkipMcpRegister` | off | Skip registering the MCP relay with Claude Code |
| `-SkipVSCodeExtensions` | off | Skip installing the C#/Unity VS Code extensions |

### What it does

1. Installs **Unity Hub** via `winget` (`Unity.UnityHub`) - used for license activation and
   project/version management, not for the install steps below
2. Installs **VS Code** via `winget` (`Microsoft.VisualStudioCode`)
3. Installs the **Unity 6 (6000) Editor** via `winget` (`Unity.Unity.6000` - the same
   signed installer Unity ships, just run silently). Unity Hub's own `--headless` CLI is
   deprecated and its `createProject` command has already been removed in current Hub
   releases, so it is deliberately not used for this. Unity's first-party MCP server
   requires Unity 6 (6000.0)+, which is why this is the only release line installed
4. Creates a new Unity **project** by locating the installed `Unity.exe` and running it
   with `-createProject -batchmode -quit` (Unity's long-standing, stable command-line
   flag - unrelated to Hub's CLI churn)
5. Locates the MCP **relay binary** at `%USERPROFILE%\.unity\relay\relay_win.exe` - the
   well-known path Unity documents for it. If it isn't there yet, the script continues
   anyway (see step 6) and warns that opening the AI Assistant window in the Editor is
   what provisions it
6. Writes `.vscode/mcp.json` in the project pointing VS Code's built-in MCP client at
   that relay path (`--mcp` argument), so it works as soon as the relay exists
7. Installs the **C# Dev Kit**, **C#**, and **Visual Studio Tools for Unity** VS Code extensions
8. Registers the relay with **Claude Code**:
   ```
   claude mcp add --scope user unityMCP -- "<relay path>" --mcp
   ```

Each step is best-effort and non-fatal: if `winget`, `code`, or `claude` isn't available,
or the Editor/project-creation step fails, the script warns and continues so you can
finish that one step manually and re-run.

### Manual steps (cannot be scripted)

- **Unity license activation** - Unity Hub requires an interactive sign-in the first
  time you use it, even for the free Personal license. `-createProject` in batchmode
  will fail with a licensing error if the Editor isn't activated yet - sign in via
  Unity Hub once, then re-run the script with `-SkipEditorInstall` to retry just the
  project-creation step.
- **AI Assistant package** - once the project is open, confirm `com.unity.ai.assistant`
  is installed via `Window > Package Manager`; add it from the Unity Registry if it's
  missing.
- **External Script Editor** - in Unity, set `Edit > Preferences > External Tools >
  External Script Editor` to Visual Studio Code.
- **Provisioning the relay** - open `Window > AI > Assistant` (or
  `Edit > Project Settings > AI > Unity MCP Server`) at least once. This is what creates
  the relay binary this script pointed VS Code/Claude Code at, and starts it running -
  the status should show "Running".
- **Approving the connection** - the first time each client connects, go to
  `Edit > Project Settings > AI > Unity MCP Server > Pending Connections` and select
  "Allow". This approval step is interactive by design and cannot be scripted.
- **Verify the bridge** - in Claude Code, `claude mcp list` should show `unityMCP`
  connected; in Unity, the client should appear under "Connected Clients".

### Troubleshooting

- **Relay path doesn't exist / MCP client can't connect** - the relay binary at
  `%USERPROFILE%\.unity\relay\relay_win.exe` is provisioned by Unity itself the first
  time you open the AI Assistant window or the Project Settings > AI page in the
  Editor - it isn't installed by this script or by `winget`. Open one of those once,
  then retry the client connection.
- **Setup script gets flagged by antivirus (e.g. `IDP.Generic`)** - this is a generic
  heuristic false positive; the script does not download-and-execute remote content
  (no `iex`/`Invoke-Expression` of anything fetched over the network). Add an
  exclusion for this folder if your AV still blocks it.

### Examples

```powershell
# Full install with defaults
./setup_unity_gamedev_env.ps1

# Custom project name/location
./setup_unity_gamedev_env.ps1 -ProjectName SpaceShooter -ProjectsRoot D:\Games

# Editor already installed - just create the project and wire up MCP
./setup_unity_gamedev_env.ps1 -ProjectName SpaceShooter -SkipEditorInstall

# Project already exists too - just wire up MCP for it
./setup_unity_gamedev_env.ps1 -ProjectName SpaceShooter -SkipEditorInstall -SkipProjectCreate
```
