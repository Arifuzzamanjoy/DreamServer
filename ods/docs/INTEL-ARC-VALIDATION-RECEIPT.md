# Intel Arc validation receipt (PR #2006)

Fill this template on a **physical Linux Intel Arc host** and attach the completed
copy to PR #2006. It is the remaining merge gate called out in review: the
automated routing contract already passes in CI, but the maintainer is holding
merge until the SYCL acceleration path is proven on real hardware.

- **Do not paste secrets** (API keys, passwords, full `.env`).
- Every section has a command to run and a blank for the evidence it produces.
- A section is "done" only when the pasted evidence matches the expected result.

## What is already proven (no hardware needed)

The fail-closed routing contract is exercised by
`ods/tests/test-intel-arc-installer-routing.sh` (wired into
`tests/contracts/test-installer-contracts.sh`, so it runs in CI). It covers:

- Healthy Arc -> `intel` backend + `docker-compose.intel.yml` overlay + `ARC` tier.
- Missing Level Zero -> fail closed to `cpu` while the profile keeps Intel vendor/identity.
- Unsupported integrated Intel and non-Linux platforms (WSL/Windows/macOS) -> `cpu`.
- AMD / CPU regression routes unchanged.

```bash
# Re-run before submitting the receipt; expect: [PASS] Intel Arc installer routing contracts
cd ods && bash tests/test-intel-arc-installer-routing.sh
```

Paste result:

```
<test output>
```

---

## Environment

| Field | Your value |
|-------|------------|
| ODS version / git SHA | `git rev-parse HEAD` |
| GPU | `lspci` line for the Arc card |
| Distribution | PRETTY_NAME + VERSION_ID from `/etc/os-release` |
| Kernel | `uname -r` (Arc needs a recent `i915`/`xe` capable kernel) |
| Install type | Bare metal / VM (must be **native Linux**, not WSL2) |
| Docker | `docker --version` and `docker compose version` |

---

## 1. Device passthrough (host -> container)

The Arc render node must be visible **inside** the llama-server container, not just
on the host.

```bash
# Host: render node present and user has render/video group access
ls -l /dev/dri/renderD*
id | tr ',' '\n' | grep -E 'render|video'

# Container: the same render node is passed through
docker compose exec llama-server ls -l /dev/dri/
```

- [ ] Host shows a `/dev/dri/renderD*` character device.
- [ ] The container lists the same `renderD*` device.

Evidence:

```
<paste host + container output>
```

## 2. Level Zero readiness

The runtime loader and a working Level Zero device must be present in the container.

```bash
docker compose exec llama-server bash -lc 'ldconfig -p | grep -i libze_loader'
docker compose exec llama-server bash -lc 'ze_info 2>/dev/null | head -40 || sycl-ls'
```

- [ ] `libze_loader` is found.
- [ ] `ze_info` / `sycl-ls` reports the Arc device (a `Level-Zero` / `gpu` backend entry).

Evidence:

```
<paste output>
```

## 3. Detection routes to the Intel backend

Confirm ODS itself selects `intel`, not a silent CPU fallback, on this host.

```bash
cd ods
ODS_LEVEL_ZERO_AVAILABLE=1 ./scripts/detect-hardware.sh --json | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); print("gpu.type=",d["gpu"]["type"],"sycl=",d["gpu"]["sycl_available"])'
./scripts/build-capability-profile.sh --output /tmp/profile.json
python3 -c 'import json; p=json.load(open("/tmp/profile.json")); print("vendor=",p["gpu"]["vendor"],"backend=",p["runtime"]["llm_backend"],"tier=",p["tier"]["recommended"],"overlays=",p["compose"]["overlays"])'
```

- [ ] `gpu.type = intel`, `sycl_available = true`.
- [ ] Profile: `vendor = intel`, `llm_backend = intel`, tier `ARC`/`ARC_LITE`, overlays include `docker-compose.intel.yml`.

Evidence:

```
<paste output>
```

## 4. llama-server GPU utilization

The model must actually run on the Arc GPU, not the CPU.

```bash
# In one terminal, watch the GPU while inference runs
sudo intel_gpu_top    # or: watch -n1 'cat /sys/class/drm/card*/device/gpu_busy_percent'

# In another terminal, confirm the server loaded the SYCL/GPU backend
docker compose logs llama-server | grep -iE 'sycl|level.?zero|offload|ngl|gpu'
```

- [ ] Server logs show layers offloaded to the SYCL/GPU device.
- [ ] `intel_gpu_top` / `gpu_busy_percent` rises during inference (idle -> active).

Evidence:

```
<paste log excerpt + a busy sample>
```

## 5. A real completion

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"Reply with the single word: arc"}],"max_tokens":16}' \
  | python3 -m json.tool
```

- [ ] Response returns generated tokens (non-empty `choices[0].message.content`).

Evidence:

```
<paste response>
```

## 6. Restart persistence

```bash
docker compose restart llama-server
sleep 20
# Re-run detection + one completion after restart
./scripts/build-capability-profile.sh --output /tmp/profile2.json
python3 -c 'import json; p=json.load(open("/tmp/profile2.json")); print("backend=",p["runtime"]["llm_backend"])'
curl -s http://127.0.0.1:8080/health
```

- [ ] After restart, backend is still `intel` and `/health` is OK.
- [ ] A completion still succeeds (repeat step 5).

Evidence:

```
<paste output>
```

## 7. Model lifecycle operations

```bash
# Load / switch / unload a model through the same path used in production
ods-cli models list
ods-cli models switch <other-model>     # or the dashboard model switcher
# confirm a completion on the new model, then switch back
```

- [ ] A model load succeeds and serves a completion.
- [ ] A model switch (and switch back) succeeds without a restart.
- [ ] No stale GPU memory / zombie process after unload (`intel_gpu_top` returns to idle).

Evidence:

```
<paste output>
```

---

## 8. CPU fail-closed proof (required by review)

Show that unsupported/incomplete Intel setups degrade to CPU **without losing the
detected hardware identity**. Run at least one of these on the same host.

```bash
# (a) Simulate a missing Level Zero runtime -> must route to cpu, keep vendor=intel
cd ods
ODS_LEVEL_ZERO_AVAILABLE=0 ./scripts/build-capability-profile.sh --output /tmp/prof-noze.json
python3 -c 'import json; p=json.load(open("/tmp/prof-noze.json")); print("vendor=",p["gpu"]["vendor"],"sycl=",p["gpu"]["sycl_available"],"backend=",p["runtime"]["llm_backend"])'

# (b) Simulate an unsupported platform (WSL) -> must route to cpu
./scripts/classify-hardware.sh --platform-id wsl --gpu-vendor intel \
  --memory-type discrete --vram-mb 16384 --device-id 0x56a0 --gpu-name "Intel Arc A770" \
  | python3 -c 'import json,sys; print("backend=",json.load(sys.stdin)["recommended"]["backend"])'
```

- [ ] (a) -> `vendor = intel`, `sycl_available = false`, `llm_backend = cpu`.
- [ ] (b) -> `backend = cpu`.

Evidence:

```
<paste output>
```

---

## Sign-off

| Field | Value |
|-------|-------|
| Tested by | |
| Date | |
| Host summary | GPU / distro / kernel |
| Result | PASS / FAIL |
| Notes | |

## Related docs

- `docs/INTEL-ARC-GUIDE.md` — supported hardware, driver setup, tiers.
- `docs/BACKEND-CONTRACT.md` — backend contract shape (`config/backends/intel.json`).
- `docs/CAPABILITY-PROFILE.md` — capability profile schema.
- `ods/tests/test-intel-arc-installer-routing.sh` — automated routing contract.
