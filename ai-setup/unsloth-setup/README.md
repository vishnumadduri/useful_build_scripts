# Unsloth Windows / Linux / AMD installers

Unsloth has two different products/install paths:

- `install_unsloth_windows_amd.ps1` installs **Unsloth Studio** on native
  Windows to `E:\UnslothStudio` by default.
- `install_unsloth_amd_wsl.ps1` installs **Unsloth Core for AMD training** in
  Ubuntu WSL, following Unsloth's AMD documentation. Its virtual environment
  is stored at `E:\UnslothAMD\venv` (mounted in WSL as `/mnt/e/UnslothAMD`).

Run it from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\install_unsloth_windows_amd.ps1
```

Use another location if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\install_unsloth_windows_amd.ps1 -InstallDir "E:\AI\UnslothStudio"
```

To prevent the app from starting automatically after installation, add
`-SkipAutoStart`.

The Windows installer persists Hugging Face's `HF_HOME` and `HF_HUB_CACHE`
user environment variables. New model downloads therefore go to
`E:\UnslothStudio\huggingface\hub`, instead of
`%USERPROFILE%\.cache\huggingface\hub`. Set `-ModelCacheDir` to use another
cache root:

```powershell
.\install_unsloth_windows_amd.ps1 -InstallDir "E:\UnslothStudio" -ModelCacheDir "E:\UnslothStudio\huggingface"
```

After installation, `E:\UnslothStudio\start.bat` launches Unsloth Studio on
port 8888 with this install's Hugging Face cache settings. Double-click it or
run it from Command Prompt.

Check for and install Unsloth Studio updates with:

```powershell
.\install_unsloth_windows_amd.ps1 -Action Update
```

The update mode calls Unsloth's official `unsloth studio update` command and
then recreates `start.bat` with the configured cache location.

## AMD training on Windows (WSL)

Run this for the AMD guide's Unsloth Core installation:

```powershell
powershell -ExecutionPolicy Bypass -File .\install_unsloth_amd_wsl.ps1
```

On its first run, it installs `Ubuntu-24.04` WSL if necessary. Restart Windows
and complete Ubuntu's initial username/password setup when prompted, then run
the command once more. Use a different ROCm wheel index only if it matches the
ROCm version reported by `amd-smi version`:

```powershell
.\install_unsloth_amd_wsl.ps1 -InstallDir "E:\AI\UnslothAMD" -RocmIndexUrl "https://download.pytorch.org/whl/rocm7.0"
```

The script downloads and executes the official installer from
`https://unsloth.ai/install.ps1`; review that script before running it if your
environment requires downloaded installers to be audited first.

## Ubuntu / Linux (Unsloth Studio)

`install_unsloth_linux.sh` is the Linux counterpart of the Windows Studio
installer. It installs apt prerequisites, runs Unsloth's official installer
(`https://unsloth.ai/install.sh`, which detects NVIDIA/AMD GPUs) and creates
`start.sh`. Defaults to `~/UnslothStudio`; do not run it as root.

```bash
./install_unsloth_linux.sh
./install_unsloth_linux.sh --install-dir /data/UnslothStudio --model-cache-dir /data/hf --skip-autostart
./install_unsloth_linux.sh --action update
```

Or from the repository root: `./run-setup.sh unsloth -- --skip-autostart`.

Launch with `~/UnslothStudio/start.sh` (port 8888). It sets `UNSLOTH_STUDIO_HOME`,
`HF_HOME` and `HF_HUB_CACHE` for that run only; nothing is written to your
shell profile. Review the downloaded installer first if your environment
requires auditing. For AMD *training* with Unsloth Core on Linux, use
`install_unsloth_amd.sh` (note it defaults to a WSL `/mnt/` path).
