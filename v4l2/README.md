# V4L2 Commands Cheat Sheet

A practical reference for inspecting, configuring, and testing V4L2 devices with `v4l2-ctl`.

---

## List Available Devices

```bash
v4l2-ctl --list-devices
```

This shows all detected capture devices and their associated `/dev/video*` nodes.

---

## Inspect Device Details

```bash
v4l2-ctl -d /dev/video0 --all
```

Use this to view supported controls, current format, driver info, and other device capabilities.

---

## List Supported Pixel Formats

```bash
v4l2-ctl -d /dev/video0 --list-formats
```

Shows the pixel formats supported by the selected device.

---

## List Formats, Resolutions, and Frame Rates

```bash
v4l2-ctl -d /dev/video0 --list-formats-ext
```

This is one of the most useful commands for understanding what combinations of format, resolution, and FPS your camera supports.

---

## Set Resolution and Pixel Format

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=YUYV
```

Replace `YUYV` with another supported format such as `MJPG` if needed.

---

## Check Current Frame Interval / FPS Settings

```bash
v4l2-ctl -d /dev/video0 --get-parm
```

Note: this reflects the driver-reported frame interval and may not exactly match actual measured FPS.

---

## Set FPS

```bash
v4l2-ctl -d /dev/video0 --set-parm=30
```

Use this to request a target frame rate from the device.

---

## Test Streaming with MMAP

```bash
v4l2-ctl -d /dev/video0 \
  --stream-mmap \
  --stream-count=100 \
  --stream-to=/dev/null
```

This is a simple streaming test that helps confirm the device can capture frames reliably.

---

## Test Streaming at a Specific Format

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1280,height=720,pixelformat=YUYV \
  --stream-mmap \
  --stream-count=100
```

Useful for validating performance at a particular resolution and pixel format.

---

## Measure Real-World Streaming Performance

```bash
v4l2-ctl -d /dev/video0 \
  --stream-mmap \
  --stream-count=200 \
  --stream-poll
```

Use a larger frame count to get a better sense of sustained performance.

---

## List Camera Controls

```bash
v4l2-ctl -d /dev/video0 --list-ctrls
```

Shows adjustable settings such as exposure, gain, focus, white balance, and more.

---

## Read or Update a Specific Control

```bash
v4l2-ctl -d /dev/video0 --get-ctrl=exposure_auto
v4l2-ctl -d /dev/video0 --set-ctrl=exposure_auto=1
```

Tip: use `--list-ctrls` first to find the exact control names available on your device.

---

## Try High FPS with MJPEG

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=MJPG \
  --stream-mmap \
  --stream-count=100
```

Many cameras provide better throughput with MJPEG than with raw formats like YUYV.

---

## Test DMABUF Streaming Support

```bash
v4l2-ctl -d /dev/video0 --stream-dmabuf
```

Use this only if your device and driver support DMABUF streaming.

---

## Check Memory-Related Support

```bash
v4l2-ctl -d /dev/video0 --all | grep -i memory
```

This can help you confirm whether a device advertises memory-related capabilities.

---

## Combined Example: Set Format and Verify FPS

```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1920,height=1080,pixelformat=YUYV \
  --set-parm=30 \
  --get-parm
```

---

## Recommended Workflow

```bash
# 1. List devices
v4l2-ctl --list-devices

# 2. Inspect supported formats and frame rates
v4l2-ctl -d /dev/video0 --list-formats-ext

# 3. Validate actual streaming performance
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=100
```

---

## Notes

- `--get-parm` does not always reflect the true achieved FPS
- Always validate with a real streaming test
- MJPEG often supports higher FPS than YUYV
- Not all devices support DMABUF
- If a command fails, check `--list-formats-ext` and `--list-ctrls` for device-specific support
