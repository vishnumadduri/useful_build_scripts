# ros2-setup

Script to install a ROS 2 distro plus common development tools on Ubuntu/Debian, and configure
the shell environment and a colcon workspace.

## Scripts

| Script | Purpose |
|---|---|
| `setup_ros2_env.sh` | Install ROS 2, dev tools, rosdep, and a colcon workspace for a given distro |

---

## setup_ros2_env.sh

```
./setup_ros2_env.sh DISTRO [VARIANT] [WORKSPACE_DIR] [--force]
```

| Argument | Default | Description |
|---|---|---|
| `DISTRO` | *required* | `humble` \| `jazzy` \| `kilted` \| `rolling` |
| `VARIANT` | `desktop` | `desktop` (full, incl. RViz/demos) \| `ros-base` (no GUI) \| `core` (minimal) |
| `WORKSPACE_DIR` | `~/ros2_ws` | colcon workspace to create (`src/` subdir) |
| `--force` | off | Skip the Ubuntu codename check and install anyway |

`iron` is intentionally not supported — it reached EOL 2024-11.

### What it does

1. Ensures a UTF-8 locale (`en_US.UTF-8`)
2. Checks the running Ubuntu codename against the one `DISTRO` requires (see table below) and
   **exits with an error** on mismatch, since the ROS 2 apt repo has no packages for the wrong
   codename and the install would fail partway through anyway — pass `--force` to attempt it regardless
3. Adds the ROS 2 apt repository (keyring + `sources.list.d`)
4. Installs the requested ROS 2 package: `ros-<distro>-<variant>`
5. Installs development tools: `ros-dev-tools` (official metapackage — `colcon` + common
   extensions, `rosdep`, `vcstool`, `argcomplete`, `rosinstall-generator`, lint tools, ...),
   plus `python3-pip`, `build-essential`, `cmake`, `git`
6. Initializes and updates `rosdep`
7. Creates a colcon workspace at `WORKSPACE_DIR/src`
8. Appends sourcing lines to `~/.bashrc` (idempotent — only added once):
   - `/opt/ros/<distro>/setup.bash`
   - `<WORKSPACE_DIR>/install/setup.bash` (once built)
   - colcon argcomplete hook
   - `ROS_DISTRO=<distro>`

**Logs:** `~/ros2-setup-<distro>.log`

### Examples

```bash
# Humble desktop install, default workspace (~/ros2_ws)
./setup_ros2_env.sh humble

# Jazzy, headless (ros-base), custom workspace
./setup_ros2_env.sh jazzy ros-base ~/dev/ros2_ws

# Rolling, minimal core install
./setup_ros2_env.sh rolling core

# Force install despite an Ubuntu codename mismatch
./setup_ros2_env.sh jazzy desktop ~/ros2_ws --force
```

### After install

```bash
source ~/.bashrc
cd ~/ros2_ws
colcon build
source install/setup.bash
```

---

## Distro → Ubuntu codename

| DISTRO | Ubuntu codename |
|---|---|
| `humble` | jammy (22.04) |
| `jazzy` | noble (24.04) |
| `kilted` | noble (24.04) |
| `rolling` | noble (24.04) |
