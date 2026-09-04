#requires -Version 5.1
<#
Installs Unity Hub, VS Code, a Unity 6 Editor, and wires up Unity's first-party
MCP server (the relay shipped with the built-in AI Assistant package,
com.unity.ai.assistant) to both VS Code and Claude Code.

This targets Unity's own MCP integration:
  https://docs.unity3d.com/Packages/com.unity.ai.assistant@2.18/manual/integration/unity-mcp-get-started.html
As of that page, Unity marks this MCP server itself as deprecated in favor of a
newer "Unity CLI" (https://docs.unity.com/en-us/unity-cli), which is not yet
documented in enough detail to script against. Revisit this script if/when that
CLI becomes the documented path.

Run from an elevated PowerShell prompt (winget installs generally want one).
#>

[CmdletBinding()]
param(
    [string]$ProjectName = "MyUnityGame",
    [string]$ProjectsRoot = "$HOME\UnityProjects",

    [switch]$SkipEditorInstall,
    [switch]$SkipProjectCreate,
    [switch]$SkipMcpRegister,
    [switch]$SkipVSCodeExtensions
)

$ErrorActionPreference = "Stop"
$ProjectPath = Join-Path $ProjectsRoot $ProjectName

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Find-UnityHubExe {
    $candidates = @(
        "$env:ProgramFiles\Unity Hub\Unity Hub.exe",
        "${env:ProgramFiles(x86)}\Unity Hub\Unity Hub.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Unity Hub*' } |
        Select-Object -First 1

    if ($entry) {
        if ($entry.InstallLocation) {
            $fromInstallLoc = Join-Path $entry.InstallLocation "Unity Hub.exe"
            if (Test-Path $fromInstallLoc) { return $fromInstallLoc }
        }
        if ($entry.DisplayIcon) {
            $iconPath = ($entry.DisplayIcon -split ',')[0]
            if (Test-Path $iconPath) { return $iconPath }
        }
    }

    return $null
}

function Find-UnityEditorExe {
    $roots = @(
        "$env:ProgramFiles\Unity\Hub\Editor",
        "${env:ProgramFiles(x86)}\Unity\Hub\Editor"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $dirs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($d in $dirs) {
            $exe = Join-Path $d.FullName "Editor\Unity.exe"
            if (Test-Path $exe) { return $exe }
        }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Unity 6000*' } |
        Select-Object -First 1

    if ($entry -and $entry.InstallLocation) {
        foreach ($rel in @("Editor\Unity.exe", "Unity.exe")) {
            $exe = Join-Path $entry.InstallLocation $rel
            if (Test-Path $exe) { return $exe }
        }
    }

    return $null
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FriendlyName
    )
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null | Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Host "    $FriendlyName already installed, skipping."
        return
    }
    Write-Host "    Installing $FriendlyName ($Id) via winget..."
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "winget reported a non-zero exit code for $FriendlyName. It may already be installed under a different source, or need a manual install."
    }
}

# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-CommandExists winget)) {
    Write-Error "winget was not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
}

# ---------------------------------------------------------------------------
Write-Step "Installing Unity Hub"
Install-WingetPackage -Id "Unity.UnityHub" -FriendlyName "Unity Hub"

$UnityHubExe = Find-UnityHubExe
if (-not $UnityHubExe) {
    Write-Warn2 "Could not locate Unity Hub.exe (checked default paths and the registry). Open it manually at least once to sign in and manage licenses/projects."
} else {
    Write-Host "    Found Unity Hub at: $UnityHubExe"
}

# ---------------------------------------------------------------------------
Write-Step "Installing Visual Studio Code"
Install-WingetPackage -Id "Microsoft.VisualStudioCode" -FriendlyName "Visual Studio Code"

# ---------------------------------------------------------------------------
# Unity Hub's own "--headless" CLI is deprecated (and its createProject command has
# already been removed in current Hub releases), so the Editor itself is installed
# straight from winget's official Unity package instead - this is the same signed
# installer Unity ships directly, just driven silently. Unity's first-party MCP
# server (com.unity.ai.assistant) requires Unity 6 (6000.0)+, so that's the only
# release line this script installs.
if (-not $SkipEditorInstall) {
    Write-Step "Installing Unity 6 (6000) Editor via winget - this can take a while"
    Install-WingetPackage -Id "Unity.Unity.6000" -FriendlyName "Unity 6000 Editor"
} else {
    Write-Host "`n==> Skipping Unity Editor install (-SkipEditorInstall)" -ForegroundColor Cyan
}

$UnityEditorExe = Find-UnityEditorExe
if ($UnityEditorExe) {
    Write-Host "    Found Unity Editor at: $UnityEditorExe"
} else {
    Write-Warn2 "Could not locate an installed Unity Editor. Project creation below will be skipped."
}

# ---------------------------------------------------------------------------
$ProjectCreated = $false
if ($UnityEditorExe -and -not $SkipProjectCreate) {
    Write-Step "Creating Unity project '$ProjectName' at $ProjectPath"
    New-Item -ItemType Directory -Force -Path $ProjectsRoot | Out-Null
    $logFile = Join-Path $env:TEMP "unity-create-project.log"
    try {
        # Start-Process -Wait is used instead of the & call operator because Unity's
        # batchmode process can return control to & before it has actually finished
        # writing the project to disk, making an immediate Test-Path check unreliable.
        $argList = @(
            "-createProject", "`"$ProjectPath`"",
            "-quit", "-batchmode",
            "-logFile", "`"$logFile`""
        )
        $proc = Start-Process -FilePath $UnityEditorExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
        $ProjectCreated = Test-Path (Join-Path $ProjectPath "Packages\manifest.json")
        if (-not $ProjectCreated) {
            Write-Warn2 "Unity exited (code $($proc.ExitCode)) but no project manifest was found. Check the log: $logFile"
            Write-Warn2 "The most common cause is Unity not being activated/licensed yet - sign in via Unity Hub once, then re-run with -SkipEditorInstall."
        }
    } catch {
        Write-Warn2 "Project creation failed: $_ (see $logFile)"
    }
} elseif ($SkipProjectCreate) {
    Write-Host "`n==> Skipping Unity project creation (-SkipProjectCreate)" -ForegroundColor Cyan
    $ProjectCreated = Test-Path (Join-Path $ProjectPath "Packages\manifest.json")
}

# ---------------------------------------------------------------------------
# Unity's first-party MCP server runs through a local relay binary that Unity
# provisions itself (the first time the AI Assistant window/Project Settings
# page is opened in the Editor) rather than through anything winget/pip can
# install. This script can only point clients at the well-known path; it
# cannot provision the binary or approve the connection - both require the
# Unity Editor UI. See "Manual steps" at the end of this run.
$RelayExe = Join-Path $env:USERPROFILE ".unity\relay\relay_win.exe"
Write-Step "Locating the Unity MCP relay"
if (Test-Path $RelayExe) {
    Write-Host "    Found relay at: $RelayExe"
} else {
    Write-Warn2 "Relay not found yet at $RelayExe."
    Write-Warn2 "It's provisioned by Unity the first time you open Window > AI > Assistant (or Edit > Project Settings > AI > Unity MCP Server) in the Editor. Client config below is written anyway - it will start working once the relay exists."
}

# ---------------------------------------------------------------------------
if ($ProjectCreated) {
    Write-Step "Writing VS Code MCP config for this project"
    $vscodeDir = Join-Path $ProjectPath ".vscode"
    New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
    $mcpJson = @{
        servers = @{
            unityMCP = @{
                type    = "stdio"
                command = $RelayExe
                args    = @("--mcp")
            }
        }
    } | ConvertTo-Json -Depth 10
    Set-Content -Path (Join-Path $vscodeDir "mcp.json") -Value $mcpJson -Encoding UTF8
    Write-Host "    Wrote $vscodeDir\mcp.json"
    Write-Warn2 "Confirm the AI Assistant package (com.unity.ai.assistant) is present via Window > Package Manager once the project is open - it ships with recent Unity 6 templates, but add it from the Unity Registry if it's missing."
} else {
    Write-Warn2 "No Unity project found at $ProjectPath - skipping .vscode\mcp.json setup."
    Write-Warn2 "Once the project exists there (Editor install already present), re-run with -SkipEditorInstall to finish MCP setup."
}

# ---------------------------------------------------------------------------
if (-not $SkipVSCodeExtensions -and (Test-CommandExists code)) {
    Write-Step "Installing VS Code extensions for Unity/C#"
    $extensions = @(
        "ms-dotnettools.csdevkit",
        "ms-dotnettools.csharp",
        "visualstudiotoolsforunity.vstuc"
    )
    foreach ($ext in $extensions) {
        # code.cmd often prints harmless Node/Chromium warnings to stderr (e.g. a
        # locked disk cache from another VS Code window). Redirecting that stream
        # (2>$null / 2>&1) makes PowerShell treat each line as a terminating error
        # under $ErrorActionPreference = "Stop", so it is deliberately left alone
        # here and just allowed to print.
        try {
            code --install-extension $ext --force | Out-Null
        } catch {
            Write-Warn2 "Failed to install VS Code extension '$ext': $_"
        }
    }
} elseif (-not (Test-CommandExists code)) {
    Write-Warn2 "'code' CLI not on PATH yet (often needs a new shell after install) - skipping extension install."
}

# ---------------------------------------------------------------------------
if (-not $SkipMcpRegister) {
    Write-Step "Registering the Unity MCP relay with Claude Code"
    if (Test-CommandExists claude) {
        try {
            claude mcp remove unityMCP --scope user 2>$null | Out-Null
        } catch {}
        try {
            claude mcp add --scope user unityMCP -- "$RelayExe" --mcp
            Write-Host "    Registered. Verify with: claude mcp list"
            if (-not (Test-Path $RelayExe)) {
                Write-Warn2 "Registered with a relay path that doesn't exist yet - it'll start working once Unity provisions it (see 'Manual steps' below)."
            }
        } catch {
            Write-Warn2 "claude mcp add failed: $_"
        }
    } else {
        Write-Warn2 "'claude' CLI not found on PATH - install Claude Code, then run:"
        Write-Warn2 "  claude mcp add --scope user unityMCP -- `"$RelayExe`" --mcp"
    }
}

# ---------------------------------------------------------------------------
Write-Step "Done. Manual steps still required"
Write-Host @"
    1. Open Unity Hub, sign in, and activate a (free Personal) license if you
       haven't already - this step needs an interactive login and can't be scripted.
    2. Open the project ($ProjectPath) from Unity Hub. Confirm the AI Assistant
       package (com.unity.ai.assistant) is installed via Window > Package Manager;
       add it from the Unity Registry if it's missing.
    3. In Unity: Edit > Preferences > External Tools > External Script Editor,
       select "Visual Studio Code".
    4. In Unity: open Window > AI > Assistant (or Edit > Project Settings > AI >
       Unity MCP Server) at least once - this provisions the relay binary this
       script pointed VS Code/Claude Code at, and starts it running.
    5. Still in Project Settings > AI > Unity MCP Server > Pending Connections,
       select "Allow" for VS Code / Claude Code the first time each one connects -
       this approval step cannot be scripted.
    6. In VS Code, open the project folder; the MCP server config is already at
       .vscode\mcp.json. In Claude Code, run 'claude mcp list' to confirm
       'unityMCP' is registered and connected.

    Note: Unity's own docs currently mark this MCP server as deprecated in favor
    of a newer "Unity CLI" (https://docs.unity.com/en-us/unity-cli). That CLI
    isn't documented in enough detail yet to script against - revisit this setup
    once it is.
"@
