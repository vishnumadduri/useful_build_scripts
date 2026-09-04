# Zephyr + LVGL + Renode

Scripts to build Zephyr LVGL demos for STM32F746G-DISCO and simulate them in Renode.

## Scripts

| Script | Purpose |
|---|---|
| `setup_zephyr_lvgl.sh` | Bootstrap Zephyr workspace, install SDK, build LVGL demo |
| `install_renode.sh` | Clone, build, and smoke-test Renode |
| `run_renode_lvgl.sh` | Simulate built firmware in Renode |

---

## Quick start

```bash
# 1. Build Renode (once)
./install_renode.sh

# 2. Build Zephyr + LVGL firmware (defaults to native 480x272)
./setup_zephyr_lvgl.sh

# 3. Simulate
./run_renode_lvgl.sh
```

---

## setup_zephyr_lvgl.sh

```
./setup_zephyr_lvgl.sh [WORKDIR] [BOARD] [DEMO] [RESOLUTION]
```

| Argument | Default | Description |
|---|---|---|
| `WORKDIR` | `~/zephyr-renode` | Zephyr west workspace root |
| `BOARD` | `stm32f746g_disco` | Zephyr board target (the only supported board) |
| `DEMO` | `hello_world` | LVGL demo to build (see table below) |
| `RESOLUTION` | `480x272` | Display preset: native `480x272` or optional `800x400` |

### Available demos

| DEMO | Sample | Description |
|---|---|---|
| `hello_world` | `subsys/display/lvgl` | Counter label + touch button |
| `music` | `modules/lvgl/demos` | Smartphone-style music player UI |
| `benchmark` | `modules/lvgl/demos` | Rendering performance test (FPS) |
| `stress` | `modules/lvgl/demos` | Rapid object creation / animation loop |
| `widgets` | `modules/lvgl/demos` | Full showcase of all built-in widgets |
| `render` | `modules/lvgl/demos` | Scene-by-scene render quality test |

### What it does

1. Installs OS prerequisites (`cmake`, `ninja`, `west`, etc.)
2. Initialises west workspace — fetches only the modules needed for STM32 + LVGL:
   `hal_stm32`, `hal_st`, `cmsis`, `cmsis_6`, `lvgl`, `picolibc`, `mbedtls`
3. Installs Zephyr SDK (version read from `zephyr/SDK_VERSION`) — skips download if already present
4. Installs Python requirements into a venv
5. Builds the selected LVGL demo with ccache acceleration

Each demo and resolution gets its own build directory:
`build_<BOARD>_<DEMO>_<RESOLUTION>/`. This allows both resolutions to remain
built at the same time.

**Logs:** `~/zephyr-build.log`

### Examples

```bash
# Default: hello_world on stm32f746g_disco at native 480x272
./setup_zephyr_lvgl.sh

# Optional 800x400 display
./setup_zephyr_lvgl.sh ~/zephyr-renode stm32f746g_disco music 800x400

# Explicit native Discovery display resolution
./setup_zephyr_lvgl.sh ~/zephyr-renode stm32f746g_disco hello_world 480x272
```

---

## install_renode.sh

```
./install_renode.sh [--run-tests] [WORKDIR]
```

| Argument | Default | Description |
|---|---|---|
| `--run-tests` | off | Run Renode unit tests after build |
| `WORKDIR` | `~/renode` | Directory to clone Renode into |

### What it does

1. Installs OS prerequisites (mono, libgtk-3, .NET 8)
2. Installs .NET 8 SDK via the official installer script if missing
3. Clones Renode with `--recurse-submodules` (or pulls + updates submodules)
4. Builds with `./build.sh`
5. Runs a smoke test (`stm32f4_discovery.resc`) headless or with GUI
6. Optionally runs the full unit test suite (`--run-tests`)

**WSLg:** GUI window opens automatically when WSLg is detected. Falls back to `--disable-xwt` (headless) on plain WSL2 or CI.

**Logs:** `~/renode-build.log`

### Examples

```bash
# Build only
./install_renode.sh

# Build + run unit tests
./install_renode.sh --run-tests

# Custom install directory
./install_renode.sh --run-tests ~/my-renode
```

---

## run_renode_lvgl.sh

```
./run_renode_lvgl.sh [WORKDIR] [BOARD] [DEMO] [RESOLUTION]
```

Arguments must match what was passed to `setup_zephyr_lvgl.sh`.

| Argument | Default | Description |
|---|---|---|
| `WORKDIR` | `~/zephyr-renode` | Same workspace used during build |
| `BOARD` | `stm32f746g_disco` | Same board used during build; only `stm32f746g_disco` is supported |
| `DEMO` | `hello_world` | Same demo built by setup script |
| `RESOLUTION` | `480x272` | Must match the resolution used during setup |

### What it does

1. Locates the Renode binary (`~/renode/renode`, `~/.local/bin/renode`, or `$PATH`)
2. Detects WSLg and sets display flags accordingly
3. Verifies the ELF artifact exists — prints a hint if not
4. Generates (or refreshes) `run_<BOARD>_<DEMO>_<RESOLUTION>.resc`
5. Launches Renode with two analyzer windows:
   - **USART1** — Zephyr shell (`uart:~$`)
   - **LTDC PixelViewer** — LVGL output at the selected resolution

### Examples

```bash
# Simulate the default 480x272 hello_world build
./run_renode_lvgl.sh

# Simulate the 800x400 music demo
./run_renode_lvgl.sh ~/zephyr-renode stm32f746g_disco music 800x400

# Simulate a previously built native-resolution demo
./run_renode_lvgl.sh ~/zephyr-renode stm32f746g_disco hello_world 480x272
```

---

## Platform notes

### STM32F746G-DISCO

- **Serial:** `sysbus.usart1`
- **Zephyr board name:** `stm32f746g_disco`

| Resolution | Zephyr configuration | Renode platform |
|---|---|---|
| `480x272` (default) | Native board device tree | `platforms/boards/stm32f7_discovery-bb.repl` |
| `800x400` (optional) | `renode/boards/stm32f746g_disco_800x400.overlay` | `renode/boards/stm32f746g_disco_800x400.repl` |

For `800x400`, the overlay changes the dimensions Zephyr uses for LVGL and
programs into the LTDC peripheral. Renode reads those LTDC timing registers
and resizes PixelViewer accordingly; the companion REPL keeps FT5336 touch
coordinates aligned with the framebuffer. The `480x272` preset uses the
upstream STM32F746G-DISCO definitions unchanged.

### Checking the active resolution

Renode opens analyzer windows at a fixed 800×600 window size. PixelViewer also
defaults to **Fit**, so both the 480×272 and 800×400 framebuffers are scaled to
fit a similarly sized window. The window size is not the emulated LCD size.

Check the **Resolution** field at the bottom of PixelViewer to see the actual
framebuffer dimensions. Select **Center** in the **Display mode** menu to show
the framebuffer without scaling. The launcher also prints the selected
resolution, firmware path, and platform before Renode starts.

### WSLg

Scripts detect WSLg by checking `/mnt/wslg`, `/tmp/.X11-unix/X0`, `$DISPLAY`, and `$WAYLAND_DISPLAY`. When present, Renode opens native GUI windows. Without WSLg, `--disable-xwt` is added automatically for headless operation.

### Zephyr SDK

The SDK version is read from `<WORKDIR>/zephyr/SDK_VERSION` after workspace init. The install check covers three conditions independently — each is only fixed if missing:

1. SDK bundle (`cmake/Zephyr-sdkConfig.cmake`)
2. ARM toolchain (`gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc`)
3. CMake user package registry (`~/.cmake/packages/Zephyr-sdk`)

### ccache

Build cache is stored at `<WORKDIR>/.ccache`. Subsequent builds of the same demo are significantly faster.
