#!/usr/bin/env bash
# spacemit-ime-build.sh (v3 -- persistent image + persistent repo/build dir + libgomp deploy)
#
# What changed vs v2:
#  - Full `-static` failed: this toolchain only ships libgomp (OpenMP) as a .so, not a
#    .a, so ld refused to statically link it. build-inside.sh now links libgcc/libstdc++
#    dynamically and ships them alongside libgomp.so with the binaries instead.
#  - This script now deploys any *.so files found in out/ next to the binaries on
#    the target board, and sets LD_LIBRARY_PATH so the dynamic linker finds them there.
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local configuration (target host, SSH key, model path, remote dir) lives in .env,
# which is git-ignored and never committed -- keeps your real hostname/IP, username,
# and filesystem paths out of the repo (this matters once the repo goes public).
# Copy .env.example to .env once and fill in your own values.
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
else
  echo "[preflight] FATAL: $SCRIPT_DIR/.env not found." >&2
  echo "[preflight] Copy .env.example to .env and fill in JUP, SSH_KEY, MODEL_PATH, REMOTE_DIR." >&2
  exit 1
fi
: "${JUP:?JUP not set in .env (e.g. user@host-or-ip)}"
: "${SSH_KEY:?SSH_KEY not set in .env}"
: "${MODEL_PATH:?MODEL_PATH not set in .env}"
: "${REMOTE_DIR:?REMOTE_DIR not set in .env}"

WORKDIR="$SCRIPT_DIR/spacemit-ime-build"
OUT_DIR="$WORKDIR/out"
REPO_DIR="$WORKDIR/repo"
LOG="spacemit-ime-build-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$OUT_DIR" "$REPO_DIR"

exec > >(tee -a "$LOG") 2>&1
echo "=== spacemit-ime-build v3 -- $(date +%Y%m%d-%H%M%S) ==="

echo
echo "--- Step 0: preflight ---"
if ! command -v docker >/dev/null 2>&1; then
  echo "[preflight] FATAL: docker CLI not found. Is OrbStack/Docker Desktop installed?"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[preflight] FATAL: docker daemon not reachable. Is OrbStack running (menu bar icon)?"
  exit 1
fi
echo "[preflight] docker OK: $(docker --version)"

if ! ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes "$JUP" 'echo ok' >/dev/null 2>&1; then
  echo "[preflight] FATAL: cannot SSH to the target board ($JUP). Check SSH_KEY / network / that the board is up."
  exit 1
fi
echo "[preflight] target board ($JUP) OK"

echo
echo "--- Step 1: build (or reuse cached) builder image ---"
echo "[image] first run: downloads toolchain + installs deps (~5-10 min). Reruns: cache hit, seconds."
if ! docker build --platform linux/amd64 -t spacemit-ime-builder:latest "$WORKDIR"; then
  echo "[image] FATAL: docker build failed. See output above."
  exit 1
fi

echo
echo "--- Step 2: cross-compile inside the persistent container (incremental after run 1) ---"
if ! docker run --rm --platform linux/amd64 \\
    -v "$REPO_DIR:/root/llama.cpp" \\
    -v "$OUT_DIR:/out" \\
    spacemit-ime-builder:latest \\
    bash /build-inside.sh; then
  echo "[build] FATAL: cross-compile failed. See output above. (Repo/build dir at $REPO_DIR is preserved for inspection and for the next rerun.)"
  exit 1
fi

if [ ! -f "$OUT_DIR/llama-bench" ]; then
  echo "[build] FATAL: expected $OUT_DIR/llama-bench not found after build. Something upstream failed silently."
  exit 1
fi
echo "[build] OK: binaries in $OUT_DIR"
file "$OUT_DIR/llama-bench" "$OUT_DIR/llama-cli" 2>/dev/null
SHIP_SO=()
while IFS= read -r -d '' f; do SHIP_SO+=("$f"); done < <(find "$OUT_DIR" -maxdepth 1 -name '*.so*' -print0 2>/dev/null)
if [ "${#SHIP_SO[@]}" -gt 0 ]; then
  echo "[build] will also ship these runtime libs: ${SHIP_SO[*]}"
else
  echo "[build] WARNING: no .so files found in $OUT_DIR -- if libgomp.so wasn't found by build-inside.sh, the run below may fail with a missing-library error."
fi

echo
echo "--- Step 3: ship binaries + runtime libs to the board and sanity-check they run ---"
ssh -i "$SSH_KEY" "$JUP" "mkdir -p $REMOTE_DIR"
scp -i "$SSH_KEY" "$OUT_DIR/llama-bench" "$OUT_DIR/llama-cli" "${SHIP_SO[@]}" "$JUP:$REMOTE_DIR/"
ssh -i "$SSH_KEY" "$JUP" "chmod +x $REMOTE_DIR/llama-bench $REMOTE_DIR/llama-cli"

echo "[deploy] checking the cross-built binary actually runs on the board..."
# NOTE: on the A100 (IME2) cores this backend tries to use a hardware TCM device
# (/dev/tcm_sync_mem) for a shared init barrier. That device doesn't exist on
# these boards (known/expected on this platform), and the code's fallback-to-heap
# path has a real upstream bug that corrupts the heap ("free(): invalid size").
# SPACEMIT_DISABLE_TCM=1 skips the TCM device attempt entirely, and
# SPACEMIT_MEM_BACKEND=posix avoids the transparent-hugepage pool that combines
# with the missing TCM device to trigger the crash.
SPACEMIT_ENV="SPACEMIT_DISABLE_TCM=1 SPACEMIT_MEM_BACKEND=posix"
# NOTE (fix after run 8): --version is no longer a valid llama-bench flag upstream.
# NOTE (fix after run 9): --list-devices is NOT safe here either -- it calls
# common_print_available_devices() -> ggml_backend_load_all_from_path(), which dlopen()s
# libggml-cpu.so a second time at runtime (dynamic backend-plugin enumeration), separate
# from however it's already loaded in-process. That second load re-runs ggml.cpp's static
# initializer, which asserts (GGML_ASSERT(prev != ggml_uncaught_exception)) because a
# std::terminate handler is already installed from the first load, and aborts. That's a
# real bug, but it's specific to the device-enumeration path -- not necessarily hit by a
# normal benchmark invocation. Use plain -h/--help instead: it printed clean usage with no
# crash last run, proving the binary loads/links/executes without going anywhere near the
# backend-plugin dlopen path. This lets Step 4's real -p/-n benchmark be the actual test of
# whether that path affects a normal run.
# NOTE (fix after run 10): -h itself runs fine (full, complete usage text printed, no
# crash) -- but this llama-bench build apparently exits non-zero for -h/--help (common
# convention: "no real benchmark args given" is treated as a usage error). Checking exit
# code alone was wrong. Check actual output content instead: if it contains the
# "usage:" header, the binary loaded, linked, and ran correctly, regardless of exit code.
HELP_OUT=$(ssh -i "$SSH_KEY" "$JUP" "LD_LIBRARY_PATH=$REMOTE_DIR $SPACEMIT_ENV $REMOTE_DIR/llama-bench -h" 2>&1)
echo "$HELP_OUT"
if ! echo "$HELP_OUT" | grep -q '^usage:'; then
  echo "[deploy] FATAL: the cross-built binary did NOT run on the board, even with LD_LIBRARY_PATH set to $REMOTE_DIR"
  echo "[deploy] and SPACEMIT_DISABLE_TCM=1 SPACEMIT_MEM_BACKEND=posix set."
  echo "[deploy] If the error mentions a missing .so, that library wasn't found/shipped by build-inside.sh --"
  echo "[deploy] check the build log above for the 'copying libgomp runtime' step. If the error instead mentions"
  echo "[deploy] a GLIBC version mismatch, that's a real sysroot/target mismatch needing toolchain-level investigation."
  echo "[deploy] Stopping here rather than reporting fake benchmark numbers."
  exit 1
fi
echo "[deploy] binary runs on the board -- proceeding to benchmark."

echo
echo "--- Step 4: A100 vs X100 direct benchmark comparison ---"
# NOTE (fix after run 11): dropped the external `taskset -c 8-15` wrapper -- it failed with
# "Invalid argument" (EINVAL from sched_setaffinity). The init banner printed on every
# invocation (even -h) already shows "cpu_mask: ff00" (= cores 8-15) and
# "perfer_core_arch_id: a064" by default, before any of our flags are parsed. That means
# the SpacemiT IME2 CPU backend does its own internal A100-core selection/pinning at the
# library level, separate from standard Linux CPU affinity -- those A100 cores likely
# aren't exposed as ordinary schedulable OS CPUs to external tools like taskset, which is
# almost certainly why taskset itself (not our benchmark args) was rejected with EINVAL.
# Let the binary's own core targeting do the job instead.
#
# NOTE (added after real numbers confirmed): confirmed against upstream source
# (ggml/src/ggml-cpu/spacemit/ime_env.cpp + ime_env.h) that core targeting is controlled
# by SPACEMIT_PERFER_CORE_ARCH, taking a hex spine_core_arch_id value:
#   core_arch_x100 = 0x5064  (IME1)
#   core_arch_a100 = 0xA064  (IME2 -- this is the "a064" we've been seeing by default)
# Note the vendor's spelling: PERFER, not PREFER.
# Leaving SPACEMIT_PERFER_CORE_ARCH unset defaults to preferring the 0xA (A100) family,
# which is why every run before this fix landed on A100 automatically. Setting it
# explicitly to 0x5064 is how we get real X100 numbers with this same IME-enabled binary
# for a direct comparison. Left at this build's own default (-r 5, not passed explicitly)
# for fast build-testing iteration -- -r 10 roughly doubled Step 4's runtime for a
# validation pass that two separate -r 5 runs already showed wasn't necessary (results
# landed within noise of each other). Bump to e.g. `-r 20` manually for a one-off
# higher-confidence measurement if ever needed, but don't make that the default.
echo "[bench] running new IME build on A100 cores (SPACEMIT_PERFER_CORE_ARCH=0xA064, IME2), 8 threads..."
ssh -i "$SSH_KEY" "$JUP" "LD_LIBRARY_PATH=$REMOTE_DIR $SPACEMIT_ENV SPACEMIT_PERFER_CORE_ARCH=0xA064 $REMOTE_DIR/llama-bench -m $MODEL_PATH -t 8 -p 512 -n 128" 2>&1

echo
echo "[bench] running new IME build on X100 cores (SPACEMIT_PERFER_CORE_ARCH=0x5064, IME1), 8 threads..."
ssh -i "$SSH_KEY" "$JUP" "LD_LIBRARY_PATH=$REMOTE_DIR $SPACEMIT_ENV SPACEMIT_PERFER_CORE_ARCH=0x5064 $REMOTE_DIR/llama-bench -m $MODEL_PATH -t 8 -p 512 -n 128" 2>&1

echo
echo "=== done: $(date +%Y%m%d-%H%M%S) ==="
echo "Log saved to: $LOG"
