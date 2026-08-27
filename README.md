# SpacemiT IME llama.cpp Build

Cross-compiles [llama.cpp](https://github.com/ggml-org/llama.cpp) for SpacemiT's RISC-V K3 boards (X100/A100 cores) with SpacemiT's IME1/IME2 vector-matrix instruction support enabled (`GGML_CPU_RISCV64_SPACEMIT=ON`).

**Status: working end-to-end.** The cross-build succeeds, ships cleanly to a K3 board, passes a real sanity check, and runs real A100 (IME2) and X100 (IME1) benchmarks side by side without crashing. See "Results" below for the numbers, and "Fix history" for the debugging trail that got here.

If you are here because you want IME-accelerated llama.cpp binaries for a K3 board and would rather not rediscover eight separate build failures yourself, this repo is for you.

## Scope

**In scope:** producing working IME-enabled RISC-V builds of llama.cpp, the toolchain and patches required to do so, benchmark numbers that characterize what this build achieves, and hardware/toolchain reference material needed to interpret those numbers.

**Out of scope:** anything specific to one person's lab. No host names, IP addresses, usernames, SSH details, network topology, or private project planning. Target-host configuration lives in `.env` at the repo root, which is git-ignored and must never be committed.

If a change would only make sense to someone who owns a particular lab, it belongs in a private repo, not here. See [`SCOPE.md`](SCOPE.md).

## Repository layout

```
.env.example                     copy to .env and fill in your own target-host values
spacemit-ime-build.sh            the orchestrator you run
spacemit-ime-build/              <-- this folder is the docker build context
    Dockerfile                   toolchain image definition
    build-inside.sh              runs inside the container; COPYied in by the Dockerfile
    out/                         build outputs (git-ignored)
    repo/                        persistent llama.cpp checkout (git-ignored)
docs/spacemit-k3-reference.md    hardware / ISA / core-targeting reference
```

**`Dockerfile` and `build-inside.sh` must stay inside `spacemit-ime-build/`.** `spacemit-ime-build.sh` runs `docker build "$WORKDIR"` with `WORKDIR=$SCRIPT_DIR/spacemit-ime-build`, so that folder *is* the build context. The Dockerfile's `COPY build-inside.sh /build-inside.sh` resolves relative to it, and neither file is visible to the build from anywhere else.

**`.env` and `.env.example` must stay at the repo root**, because `spacemit-ime-build.sh` sources `"$SCRIPT_DIR/.env"`.

## Documentation

[`docs/spacemit-k3-reference.md`](docs/spacemit-k3-reference.md) — X100/A100 architecture reference: IME generations, core targeting via environment variables, the A100 affinity fence, and the toolchain trap. Read it before trying to interpret any benchmark you run on this hardware.

## Why this exists

SpacemiT's stock Bianbu-distro `llama.cpp` package is built with a plain toolchain that doesn't understand the K3 cluster's IME matrix instructions (`vmadot`, etc.). Real measurements on this hardware showed the A100 cores running roughly 5x *slower* than the X100 cluster on ordinary compiled code as a result — the opposite of their intended "AI core" role. This project builds llama.cpp with SpacemiT's own cross-toolchain and the upstream `GGML_CPU_RISCV64_SPACEMIT` backend instead, to get real IME-accelerated numbers on real hardware, on both core types.

**If you benchmark K3 with a stock-toolchain build, you are measuring the compiler, not the chip.** That single point is the reason this repo exists.

## How it works

- `spacemit-ime-build/Dockerfile` builds a `linux/amd64` Ubuntu 22.04 image with SpacemiT's official `v1.2.4` cross-toolchain and build dependencies baked in. Docker's layer cache makes rebuilds near-instant after the first run.
- `spacemit-ime-build/build-inside.sh` runs inside that container: clones/updates `llama.cpp`, applies a small source patch (see below), configures and builds with CMake, and copies the resulting riscv64 binaries plus runtime shared libraries to a mounted `/out` directory.
- `spacemit-ime-build.sh` is the orchestrator you actually run: builds the Docker image, runs `build-inside.sh` inside it, then ships the binaries to the target K3 board over SSH, sanity-checks that they run, and runs the real benchmark on both core types.

## Usage

1. Copy `.env.example` to `.env` (both at the repo root) and fill in your own target-host details (`JUP`, `SSH_KEY`, `MODEL_PATH`, `REMOTE_DIR`). `.env` is git-ignored and never committed.
2. Run:

```bash
./spacemit-ime-build.sh
```

Requires Docker (or OrbStack) running locally, and key-based SSH access to the target K3 board.

## Results

IME-accelerated results, Qwen2.5-0.5B-Instruct Q4_K_M, 8 threads, cluster selected explicitly via `SPACEMIT_PERFER_CORE_ARCH` so both runs use the same binary and build:

| cores | IME | pp512 (t/s) | tg128 (t/s) |
| --- | --- | --- | --- |
| **A100** | IME2 (`0xA064`) | **368.93 +/- 0.24** | **49.10 +/- 0.03** |
| **X100** | IME1 (`0x5064`) | 41.83 +/- 0.02 | 25.96 +/- 0.19 |
| | **A100 advantage** | **~8.8x** | **~1.9x** |

**This flips the stock-package conclusion.** With IME enabled, A100 beats X100 by ~8.8x on pp512 and ~1.9x on tg128 — a meaningfully different scaling pattern between prompt-processing (batched) and token-generation (sequential) workloads. **Bottom line: run inference on the A100 cluster using this IME-enabled build — not the stock Bianbu package, and not X100.** The earlier "X100 is better" conclusion was purely a toolchain artifact, not a real hardware limitation.

Repeatability: two independent A100 runs landed within noise of each other (`pp512` 374.25 +/- 0.05 and 373.14 +/- 0.17 in an earlier session), which is a good sign the pipeline itself is stable and these numbers are real/reproducible.

For reference, the earlier stock (non-IME) A100 package measured `pp512 = 5.27 +/- 0.02 t/s`, and `tg128` on that package never completed inside a 10-minute limit.

## The source patch

Upstream's `ime_env.cpp` has a real bug: on hardware without a `/dev/tcm_sync_mem` device node (i.e. most real K3 boards), it falls back to a heap allocation for a shared init barrier — but that fallback path corrupts the heap (`free(): invalid size` at runtime). `build-inside.sh` applies a small, idempotent patch on top of a fresh clone that:

1. Honors `SPACEMIT_DISABLE_TCM` by skipping the doomed TCM `open()` attempt entirely when it's set (upstream only half-implements this env var — it gates a different, earlier code path).
2. Replaces the `new[]`/`delete[]` heap fallback with `posix_memalign`/`free`, matching the pool allocator's alignment contract.

The patch only touches a fresh/pulled checkout of upstream `llama.cpp` (nothing is vendored into this repo), so it stays current with upstream automatically, and is skipped on repeat runs once already applied.

## Core targeting (A100 vs X100)

Confirmed directly against upstream source (`ggml/src/ggml-cpu/spacemit/ime_env.cpp` and `ime_env.h`): core selection is controlled by the `SPACEMIT_PERFER_CORE_ARCH` env var, which takes a hex `spine_core_arch_id` value:

| value | cores | IME generation |
| --- | --- | --- |
| `0x5064` | X100 | IME1 |
| `0xA064` | A100 | IME2 |

Note the vendor's spelling: **PERFER**, not PREFER.

Left unset, the binary defaults to preferring whichever core family has arch-id head `0xA` (i.e. A100) — which is why every run before this fix landed on A100 automatically, with `cpu_mask: ff00` and `perfer_core_arch_id: a064` printed in its startup banner regardless of any benchmark flags passed. `spacemit-ime-build.sh` now sets this env var explicitly for both a real A100 run and a real X100 run in the same invocation, so the two are always a true side-by-side comparison on the same binary/build.

**A100 cores are not controllable via standard Linux CPU affinity** — an external `taskset -c 8-15` wrapper reliably fails with `Invalid argument` (EINVAL), because this backend does its own internal core pinning at the library level rather than relying on `sched_setaffinity`. Use `SPACEMIT_PERFER_CORE_ARCH` (or `SPACEMIT_PERFER_CORE_ID` for individual core ids, also read directly from upstream source) instead of `taskset` for any future core-targeting needs.

## Known limitations

- **Text-only. No multimodal binary is built or shipped.** `build-inside.sh` copies only `llama-bench` and `llama-cli`, so **no vision-language model can be run on the board with this build at all.** Adding that requires building llama.cpp's multimodal path (`libmtmd` / the `llama-mtmd-cli` target, and optionally `llama-server`) and staging a VLM GGUF together with its matching `mmproj-*.gguf` projector — the projector is a separate file and is easy to overlook. Expect the static-vs-dynamic C++ runtime issue described in fix-history item 2 to resurface, since multimodal adds link surface. Also worth running with `GGML_SCHED_DEBUG=2`: vision encoders use different ops than text transformers, and if IME doesn't implement them the work falls back to scalar **silently**, giving you a working but slow binary and no error.
- All results so far are from a **0.5B** text model. They demonstrate the IME backend works; they say little about 7B-class latency or bandwidth behavior.
- `llama-bench -h`/`--help` exits non-zero even on success in this build (not a bug in this repo — just this llama-bench version's convention). The deploy sanity check in `spacemit-ime-build.sh` checks output content (`usage:` header) rather than exit code for this reason.

## Fix history (for the next time something in this pipeline breaks)

1. **`free(): invalid size` crash on the A100 cores.** Root cause: `ime_env.cpp`'s TCM-barrier fallback path uses a heap allocation pattern that corrupts the heap on hardware without `/dev/tcm_sync_mem`. Fixed by the source patch described above.
2. **Same crash persisted after the patch.** Root cause: statically linking `libgcc`/`libstdc++` into the executables while GGML backend `.so` plugins are still `dlopen()`'d and only ever linked dynamically created two ABI-incompatible C++ runtimes in one process, corrupting the heap when one runtime freed memory the other allocated. Fixed by linking `libgcc`/`libstdc++` dynamically for the executables too, and shipping `libstdc++.so`/`libgcc_s.so` alongside `libgomp.so`.
3. **Crash persisted again after that fix, identically.** Root cause: `build/CMakeCache.txt` persisted across incremental rebuilds and kept re-applying the old static-link flags, since `cmake -B build` reuses cached variable values whenever a rerun doesn't explicitly override them. Fixed by clearing `build/CMakeCache.txt`/`build/CMakeFiles/CMakeTmp` before each reconfigure and explicitly passing empty `-DCMAKE_EXE_LINKER_FLAGS`/`-DCMAKE_SHARED_LINKER_FLAGS`.
4. **Deploy sanity check failed on `--version`.** Not a real crash — this llama-bench build no longer supports `--version` at all. Switched the check to `--list-devices`.
5. **`--list-devices` uncovered a second, real, unrelated crash** (`GGML_ASSERT(prev != ggml_uncaught_exception)`). Root cause: `--list-devices` triggers `ggml_backend_load_all_from_path()`, which `dlopen()`s `libggml-cpu.so` a second time at runtime for backend-plugin enumeration, re-running its static initializer and hitting an already-installed `std::terminate` handler. This is real but specific to the device-enumeration path. Switched the check to plain `-h`.
6. **`-h` also "failed" the sanity check**, but with zero actual error output. Root cause: `-h` prints complete, correct usage text but this build exits non-zero for it regardless, and the check was gating on exit code. Fixed by checking output content (`usage:` header) instead of exit code.
7. **Step 4's `taskset -c 8-15` failed with `Invalid argument`.** Root cause: A100 cores aren't controllable via standard affinity syscalls — this backend does its own internal core pinning. Removed the `taskset` wrapper.
8. **X100 numbers were never being collected**, since the binary silently defaults to A100 core targeting. Root cause identified directly from upstream source: `SPACEMIT_PERFER_CORE_ARCH` (hex `spine_core_arch_id`) controls this, defaulting to the `0xA` (A100) family when unset. Fixed by setting it explicitly to `0xA064` and `0x5064` for two separate, real, comparable runs in Step 4.

### If you are debugging this pipeline again, read this first

Three of the eight items above were the *same visible symptom* with three different root causes, and item 3 was the fix being silently reverted by a stale cache. **Verify the file on disk (checksum or grep) before concluding a fix didn't work**, and have long-running scripts print their own checksum at the top of the log. If a symptom survives a fix you are confident in, suspect a *second* root cause rather than undoing the fix.

A related failure mode worth knowing about: this repo was once re-created from scratch, and the copies of `build-inside.sh` and `Dockerfile` were restored to the repo root instead of into `spacemit-ime-build/`, with shell line continuations double-escaped (`\\` instead of `\`) in the process. Neither mistake is visible by reading the file casually, and both break the build in confusing ways. If the build fails immediately after any bulk file restore, check file *locations* and `bash -n` output before debugging anything about the toolchain.

## Development note

This project was built collaboratively with Claude (Anthropic) — debugging, the source-patch design, and the fix history documented above were AI-assisted, with every step validated against real hardware.
