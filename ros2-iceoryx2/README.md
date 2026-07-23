# ros2-iceoryx2

Docker build for ROS 2 (rolling) with the [rmw_iceoryx2](https://github.com/ekxide/rmw_iceoryx2) RMW
implementation, built from source on top of `ros:rolling-ros-base`.

## Files

- **Dockerfile** — original single-stage build. Simple, but produces a large (~19GB) image because
  it keeps the full `ros2.repos` source tree, `colcon` build/log directories, and every rosdep
  build-time dependency (Qt6, OpenCV, cargo, clang, etc.) in the final image.
- **Dockerfile.build** — builder stage only. Imports ROS 2 + iceoryx2 sources, installs build
  dependencies, and runs `colcon build` (without `--symlink-install`, so `install/` is self-contained
  and safe to copy elsewhere).
- **Dockerfile.runtime** — slim final image (**2.0GB**, verified). Copies only the compiled
  `install/` output from the builder, plus the exec-time (not build-time) dependencies for just the
  packages actually built — resolved via `colcon list --packages-up-to ... --paths-only` piped into
  `rosdep install --dependency-types=exec`, over a BuildKit bind-mount so the full `ros2.repos`
  source tree (383 packages) never becomes a committed layer. Scoping to the 178 packages actually
  selected by `--packages-up-to` (rather than all 383) is what keeps this from re-pulling in
  Qt6/OpenCV/etc. — the full source tree includes rviz/rqt/vision-demo packages this build never
  compiles, and naively running rosdep against all of `/workspace/src` installs their exec deps too.

## Build (slim, two-stage)

```bash
docker build -f Dockerfile.build -t ros-iceoryx2-builder .
docker build -f Dockerfile.runtime -t ros-iceoryx2 .
```

`Dockerfile.runtime` references the `ros-iceoryx2-builder` image by name via `COPY --from=`, so the
builder image must exist locally before the second build runs.

## Build (single-stage, full image, one pass)

Builds everything — source import, build deps, compile, and all rosdep build-time packages — into
one ~19GB image using the plain `Dockerfile`. Simpler than the two-stage path, at the cost of image
size; useful for local development where you don't care about final image size.

1. From the repo root, move into this directory (the build context must contain `Dockerfile`):
   ```bash
   cd ros2-iceoryx2
   ```
2. Build the image (takes ~15-20 minutes: source checkout, rosdep install, then `colcon build`):
   ```bash
   docker build -t ros-iceoryx2:full -f Dockerfile .
   ```
3. Run it:
   ```bash
   docker run -it --rm ros-iceoryx2:full
   source /workspace/install/setup.bash
   ros2 run rmw_iceoryx2_talker_demo_nodes talker_strings
   ```

To rebuild from scratch (ignore Docker's layer cache), add `--no-cache` to step 2.

## Run

```bash
docker run -it --rm ros-iceoryx2
source /workspace/install/setup.bash
ros2 run rmw_iceoryx2_talker_demo_nodes talker_strings
```

## Notes

- `rti-connext-dds-7.7.0`, `fastcdr`, and `urdfdom_headers` are skipped during `rosdep install`
  (`--skip-keys`) because the RTI Connext DDS package requires interactively accepting a license,
  which breaks non-interactive Docker builds. This matches the skip-list used in
  [OSRF's official ROS 2 source Dockerfile](https://github.com/osrf/docker_images/blob/master/ros2/source/source/Dockerfile).
- `RMW_IMPLEMENTATION=rmw_iceoryx2_cxx` selects the iceoryx2 middleware at build time for the demo
  nodes target; set the same env var at runtime to use it when running ROS 2 nodes.
