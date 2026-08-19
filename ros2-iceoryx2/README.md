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
3. Run it (talker + listener in the same container — see [Run](#run) below for why):
   ```bash
   docker run -it --rm --name ros-iceoryx2-demo ros-iceoryx2:full
   source /workspace/install/setup.bash
   ros2 run rmw_iceoryx2_talker_demo_nodes talker_strings
   ```

To rebuild from scratch (ignore Docker's layer cache), add `--no-cache` to step 2.

## Run

iceoryx2 is a shared-memory transport: talker and listener rendezvous through `/dev/shm` and a
Unix domain socket, so **both nodes must run in the same container** (same IPC namespace and
`/dev/shm`) — two separate `docker run` invocations are two separate containers with isolated
`/dev/shm` by default and will never see each other, even on the same host and image. Either open
a second terminal into the *same* running container with `docker exec`, or run one node in the
background of a single container.

**Terminal 1 — start the container and the listener:**
```bash
docker run -it --rm --name ros-iceoryx2-demo ros-iceoryx2
source /workspace/install/setup.bash
ros2 run rmw_iceoryx2_talker_demo_nodes listener_strings
```

**Terminal 2 — attach to the same container and start the talker:**
```bash
docker exec -it ros-iceoryx2-demo bash -lc \
  "source /workspace/install/setup.bash && ros2 run rmw_iceoryx2_talker_demo_nodes talker_strings"
```

If you do need talker and listener in separate containers (e.g. separate services in
docker-compose), share the IPC namespace explicitly — e.g. run the second container with
`--ipc=container:ros-iceoryx2-demo` (or give both containers `--ipc=host` to share the host's
`/dev/shm`).

**Verified working** — talker output:
```
[INFO] [talker_strings]:
╭─ SENT
│  string_value  Hello 0
╰────────────────────────────
```
listener output:
```
[INFO] [listener_strings]:
╭─ RECV · seq 0
│  string_value  Hello 0
╰────────────────────────────
```

## Notes

- `rti-connext-dds-7.7.0`, `fastcdr`, and `urdfdom_headers` are skipped during `rosdep install`
  (`--skip-keys`) because the RTI Connext DDS package requires interactively accepting a license,
  which breaks non-interactive Docker builds. This matches the skip-list used in
  [OSRF's official ROS 2 source Dockerfile](https://github.com/osrf/docker_images/blob/master/ros2/source/source/Dockerfile).
- `RMW_IMPLEMENTATION=rmw_iceoryx2_cxx` selects the iceoryx2 middleware at build time for the demo
  nodes target; set the same env var at runtime to use it when running ROS 2 nodes.
- Both nodes print `rcutils_set_error_state()` / "failed to resolve symbol ..." warnings and
  `Failed to add event handler for incompatible qos/type; not supported` on startup. These are
  harmless — `rmw_iceoryx2_cxx` doesn't implement the optional service/client-introspection and
  QoS-event-handler symbols that `rmw_implementation` probes for, but pub/sub (what these demo
  nodes use) is unaffected. Confirmed by running the two-stage build end-to-end: `talker_strings`
  and `listener_strings` in the same container exchange messages correctly despite the warnings.
