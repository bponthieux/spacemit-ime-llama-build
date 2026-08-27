# SpacemiT K3 (X100/A100) -- Architecture & Toolchain Reference

Reference notes for anyone building or benchmarking on SpacemiT K3 silicon. Everything here was confirmed either against upstream source or by direct measurement on real hardware.

## The two clusters

K3 is a 16-core heterogeneous RISC-V part:

| cluster | cores | clock | VLEN | IME generation |
| --- | --- | --- | --- | --- |
| X100 | 8 (cpu0-7) | 2.2 GHz | 256-bit | IME1 (`0x5064`) |
| A100 | 8 (cpu8-15) | 1.8 GHz | 1024-bit | IME2 (`0xA064`) |

There is **no discrete NPU**. The "AI" capability is the IME (Integer Matrix Extension) instructions in the A100 cluster's vector unit, reached through ordinary compiled code -- not a separate accelerator with its own driver and runtime.

Both clusters report **identical ISA strings**, including the `h` (hypervisor) extension on all 16 harts. You cannot tell the clusters apart by reading ISA strings; the real differences are VLEN and IME generation.

## The toolchain trap

**This is the single most important thing on this page.** A stock GCC cannot compile IME instructions:

```
unrecognized opcode 'vmadot', extension 'xsmtvdotii' required
```

SpacemiT's own cross-toolchain (v1.2.4 as used here) is required. The consequence is that the distro-packaged `llama.cpp` in Bianbu (`8681+dfsg-1` from `archive.spacemit.com/bianbu4`) is a **stock build with no IME support at all**.

Measured impact of build configuration alone, same hardware, same model:

| build | A100 pp512 | X100 pp512 |
| --- | --- | --- |
| stock distro package | 5.27 t/s | 27.31 t/s |
| IME-enabled (this repo) | 368.93 t/s | 41.83 t/s |

That is roughly a **70x swing from build configuration alone**, and it *inverts the ranking of the two clusters*. With a stock build the A100 cluster looks ~5x slower than X100 and appears broken; with an IME build it is ~8.8x faster. Any K3 benchmark that does not state its toolchain is uninterpretable.

## Core targeting

Core selection is controlled by environment variables read in `ggml/src/ggml-cpu/spacemit/ime_env.cpp`:

| variable | purpose |
| --- | --- |
| `SPACEMIT_PERFER_CORE_ARCH` | hex `spine_core_arch_id`: `0x5064` = X100/IME1, `0xA064` = A100/IME2 |
| `SPACEMIT_PERFER_CORE_ID` | target individual core ids |

Note the vendor's spelling: **`PERFER`**, not `PREFER`. That is not a typo in this document.

Unset, it defaults to the `0xA` (A100) family. The startup banner prints `cpu_mask: ff00` and `perfer_core_arch_id: a064` on every invocation -- including `-h` -- before any of your own flags are parsed. If you forget to set this variable, every run silently lands on A100 and you will never collect X100 numbers.

**`taskset` does not work for this.** An external `taskset -c 8-15` fails with `Invalid argument` (EINVAL from `sched_setaffinity`), because the IME backend does its own internal core pinning at the library level, below standard Linux affinity. Use the environment variables.

## The A100 affinity fence

For ordinary (non-IME) processes, the kernel fences cpu8-15 off from `sched_setaffinity` entirely -- attempts return EINVAL. Unlocking is via a world-writable proc node:

```bash
echo $$ > /proc/set_ai_thread   # then exec your workload
```

Writing a PID unfences that process **and its children**. Two things to know:

- **It is a one-way gate.** Once unfenced, a process cannot be returned to X100-only scheduling. Collect X100 control numbers from a process that was *never* unlocked, or the comparison is invalid.
- The IME backend bypasses this mechanism entirely via `SPACEMIT_PERFER_CORE_ARCH`, so you generally do not need the proc node when using an IME build.

## Threading behavior

SpacemiT's own IME code spawns **six pthreads pinned to cores 8-13** -- not all eight A100 cores -- using a `spine_barrier_t` spinlock barrier and a persistent tile work loop. Do not assume `-t 8` maps onto eight A100 cores; the library's internal topology is its own.

## Do not benchmark this chip with sha256

A cautionary note, learned the hard way. `openssl speed sha256` is a **misleading proxy** on this hardware: SHA-2 operates on 256-bit element groups, so the A100's 1024-bit vector width contributes nothing, and A100 measures at roughly 27% of X100 aggregate throughput. That number says nothing about matrix-multiply performance, where the same cluster is ~8.8x faster.

Measured scalar/crypto figures, for context only:

| measurement | X100 | A100 |
| --- | --- | --- |
| AES-256-GCM | ~1.90 GB/s | -- |
| SHA-256 @16K | ~1.56 GB/s | 424 MB/s single-core |
| SHA-256, 8 workers | ~12.5 GB/s | ~3.4 GB/s |

An independent measurement (`brucehoult/k3_ai`) puts A100 scalar performance at ~40% of X100, consistent in direction with the above. **Benchmark the workload you actually care about, not a convenient proxy.**

## External calibration figures

Third-party llama.cpp numbers on this silicon, useful for sanity-checking your own:

| model | pp (t/s) | tg (t/s) |
| --- | --- | --- |
| Qwen3-30B-A3B Q4 | 23.9 | 8.4 |
| SmolLM-1.7B Q4 | 61.7 | 15.2 |
| Qwen3-0.6B Q4_K_M | -- | 35-40 |

SpacemiT's own marketing claims ">10 Tokens/s @ 30B", 60 TOPS, and "84% of the overall intelligence performance of a 235B model". Treat the last one as marketing.

## Runtime environment variables worth knowing

| variable | why |
| --- | --- |
| `SPACEMIT_DISABLE_TCM=1` | skips the `/dev/tcm_sync_mem` attempt; needed on boards lacking that device node |
| `SPACEMIT_MEM_BACKEND=posix` | avoids the transparent-hugepage pool that combines with a missing TCM device to trigger a heap crash |
| `GGML_SCHED_DEBUG=2` | shows per-op backend assignment -- the only reliable way to catch ops silently falling back to scalar |

That last one matters more than it looks. If IME does not implement an op, the work falls back to scalar **without any error**, and you get a working-but-slow binary with no indication why.
