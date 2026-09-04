# vendor/

Assets `setup_comfyui_env.ps1`'s `-Action InstallNode -Node Hunyuan3D2` copies
into a fresh [kijai/ComfyUI-Hunyuan3DWrapper](https://github.com/kijai/ComfyUI-Hunyuan3DWrapper)
clone to make texture generation work on GPU paths where the upstream
`custom_rasterizer` C++ extension can't be built (notably AMD/ROCm - the
Windows ROCm torch wheel can't link *any* C++ extension, GPU or CPU variant).

| File | Purpose |
|---|---|
| `torch_rasterizer.py` | Pure-PyTorch reimplementation of `custom_rasterizer`'s `rasterize`/`interpolate`. No compiler needed anywhere; runs on whatever device the tensors are on (CUDA, ROCm, MPS, CPU). Verified against a literal transcription of the native kernel's C++ logic. |
| `hunyuan3d2-torch-rasterizer.patch` | Patches `hy3dgen/texgen/differentiable_renderer/mesh_render.py` so it falls back to `torch_rasterizer.py` automatically when `import custom_rasterizer` fails, instead of crashing. Idempotent - the script detects if it's already applied and skips cleanly. |

Both originate from a proof-of-concept (`rasterizer_poc/`) and a deployed fix
built and verified elsewhere on this machine against a real AMD Radeon AI PRO
R9700 (ROCm 7.2.1) - confirmed working end-to-end (a real mesh rasterizes
correctly on the ROCm device with zero compiled extensions present) before
being adopted here. `torch_rasterizer.py`'s own docstring and
`tests/test_torch_rasterizer.py` (not vendored here - see the original PoC)
have the full semantics writeup, including why the CPU fallback path in
upstream's native extension isn't reachable either on this GPU path.

If upstream's `mesh_render.py` changes enough that the patch stops applying,
the setup script warns and continues (same as
[`../../ai-setup/gaming/hunyuan3d2-setup`](../../ai-setup/gaming/hunyuan3d2-setup)'s `windows-fixes.patch`)
rather than failing the whole `InstallNode` run - apply the equivalent change
by hand in that case, or diff `hunyuan3d2-torch-rasterizer.patch` against the
new file to see what moved.
