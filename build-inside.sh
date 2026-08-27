set -euo pipefail
cd /root

if [ -d /root/llama.cpp/.git ]; then
  echo '[container] existing checkout found at /root/llama.cpp -- pulling latest instead of re-cloning...'
  cd /root/llama.cpp
  git pull --ff-only || echo '[container] git pull failed/skipped -- continuing with the existing checkout as-is'
else
  echo '[container] no existing checkout -- cloning fresh (this only happens once, into the persistent mount)...'
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /root/llama.cpp
  cd /root/llama.cpp
fi

echo
echo '[container] applying source patch for SpacemiT IME2 init_barrier heap-corruption bug...'
IME_ENV_CPP="ggml/src/ggml-cpu/spacemit/ime_env.cpp"
if [ ! -f "$IME_ENV_CPP" ]; then
  echo "[container] FATAL: $IME_ENV_CPP not found -- upstream may have moved/renamed it."
  exit 1
fi
if grep -q 'disable_tcm_for_barrier' "$IME_ENV_CPP"; then
  echo '[container] ime_env.cpp already patched -- skipping.'
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo '[container] python3 not found, installing (needed for the source patch)...'
    apt-get update -qq && apt-get install -y -qq python3 >/dev/null
  fi
  python3 - "$IME_ENV_CPP" <<'PATCH_PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()

# Root cause (confirmed via source review against the exact crash log):
# spine_mem_pool_shared_mem_alloc() unconditionally open()s /dev/tcm_sync_mem for the
# init_barrier allocation, regardless of SPACEMIT_DISABLE_TCM -- that env var only gates a
# separate, earlier use_tcm/per-thread scratch-buffer check in this same constructor.
# On hardware without that device node the open() fails and the code falls back to a
# plain `new spine_barrier_t[...]` heap allocation -- which is where "free(): invalid
# size" crashes the process on the A100 (IME2) cores.
#
# Fix: (1) actually honor SPACEMIT_DISABLE_TCM here by skipping the doomed TCM open()
# attempt entirely when it's set, and (2) replace the new[]/delete[] heap fallback with
# posix_memalign/free (matching the pool allocator's alignment contract) to rule out any
# operator-new[]-array-cookie mismatch from libstdc++.

pattern1 = re.compile(
    r'init_barrier\\s*=\\s*static_cast<spine_barrier_t\\s*\\*>\\(spine_mem_pool_shared_mem_alloc\\(init_barrier_size,\\s*alignof\\(spine_barrier_t\\)\\)\\);'
)
replacement1 = (
    'const char * disable_tcm_env_for_barrier = getenv("SPACEMIT_DISABLE_TCM");\\n'
    '    const bool disable_tcm_for_barrier = disable_tcm_env_for_barrier != nullptr && strcmp(disable_tcm_env_for_barrier, "0") != 0;\\n'
    '    init_barrier = disable_tcm_for_barrier ? nullptr : static_cast<spine_barrier_t *>(spine_mem_pool_shared_mem_alloc(init_barrier_size, alignof(spine_barrier_t)));'
)
s, n1 = pattern1.subn(replacement1, s, count=1)
if n1 != 1:
    print(f"PATCH FAILED: pattern1 matched {n1} times", file=sys.stderr)
    sys.exit(1)

pattern2 = re.compile(r'init_barrier\\s*=\\s*new\\s+spine_barrier_t\\[spine_init_barrier_count\\];')
replacement2 = (
    'if (posix_memalign(reinterpret_cast<void **>(&init_barrier), alignof(spine_barrier_t), init_barrier_size) != 0) {\\n'
    '            throw std::bad_alloc();\\n'
    '        }'
)
s, n2 = pattern2.subn(replacement2, s, count=1)
if n2 != 1:
    print(f"PATCH FAILED: pattern2 matched {n2} times", file=sys.stderr)
    sys.exit(1)

pattern3 = re.compile(r'delete\\[\\]\\s*init_barrier;')
replacement3 = 'std::free(init_barrier);'
s, n3 = pattern3.subn(replacement3, s, count=1)
if n3 != 1:
    print(f"PATCH FAILED: pattern3 matched {n3} times", file=sys.stderr)
    sys.exit(1)

if '#include <cstdlib>' not in s:
    s = s.replace('#include "ime_env.h"', '#include "ime_env.h"\\n#include <cstdlib>\\n#include <cstring>', 1)

p.write_text(s)
print("ime_env.cpp patched: barrier now honors SPACEMIT_DISABLE_TCM and uses posix_memalign/free for the heap fallback")
PATCH_PY
fi

if [ ! -f cmake/riscv64-spacemit-linux-gnu-gcc.cmake ]; then
  echo '[container] FATAL: cmake/riscv64-spacemit-linux-gnu-gcc.cmake not found in this llama.cpp checkout -- upstream may have moved/renamed it.'
  exit 1
fi

TC="${RISCV_ROOT_PATH:-/opt/spacemit-toolchain}"
echo "[container] RISCV_ROOT_PATH=${TC}"
ls "$TC/bin" 2>/dev/null | head -10 || echo '[container] WARNING: unexpected toolchain layout, bin/ not found where expected'

# NOTE (fix after run 3): full `-static` failed because this toolchain only ships
# libgomp (OpenMP) as a .so, not a .a -- ld refuses to statically link a dynamic-only
# lib. Fix (that run): static-link only libgcc/libstdc++, keep BUILD_SHARED_LIBS=OFF,
# and ship libgomp.so alongside the binaries.
#
# NOTE (fix after run 6): the static-libgcc/static-libstdc++ flag above turned out to
# cause a DIFFERENT, worse bug: llama.cpp loads its GGML backends (e.g. libggml-cpu.so)
# via dlopen() at runtime. That .so is only ever linked dynamically against the
# toolchain's libstdc++.so.6/libgcc_s.so -- it never sees our static-link flag. So the
# process ended up with TWO separate, ABI-incompatible copies of the C++ runtime (one
# baked statically into llama-bench/llama-cli, one loaded dynamically for the .so
# plugins) both touching the same global std::locale/iostream singletons. When one
# runtime's allocator freed memory the other runtime's allocator had allocated, glibc's
# malloc detected the corrupted heap block header and aborted -- this was the real cause
# of the "free(): invalid size" crash on the board (confirmed via gdb backtrace; it was
# NOT related to TCM/init_barrier, despite that unrelated log line appearing right before
# it). Fix: go back to dynamic libgcc/libstdc++ for the executables too, so the exe and
# every dlopen()'d backend .so share one C++ runtime, and ship libstdc++.so/libgcc_s.so
# alongside libgomp.so below.
#
# NOTE (fix after run 7): build/ persisting across runs also persists CMake's own
# CMakeCache.txt -- which still had -static-libgcc -static-libstdc++ cached from the
# very first configure, from before the dynamic-linking fix existed. Removing that flag
# from THIS script wasn't enough: cmake -B build reuses a cached variable's old value
# whenever the invocation doesn't explicitly set it, so the stale static flags kept
# winning silently and every rebuild kept reproducing the exact same crash. Clearing
# just the cache/config (not the whole build/ tree -- compiled .o files are untouched,
# so this stays fast) guarantees this run's flags are the ones that actually apply.
echo '[container] clearing stale CMake cache/config (object files are preserved) so this run flags cannot be silently overridden by an old cached value...'
rm -f build/CMakeCache.txt
rm -rf build/CMakeFiles/CMakeTmp

echo '[container] configuring (build/ persists across runs -- this reconfigure is fast, and cmake --build below is incremental)...'
cmake -B build \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DBUILD_SHARED_LIBS=OFF \\
    -DGGML_CPU_RISCV64_SPACEMIT=ON \\
    -DGGML_CPU_REPACK=OFF \\
    -DLLAMA_OPENSSL=OFF \\
    -DGGML_RVV=ON \\
    -DGGML_RV_ZVFH=ON \\
    -DGGML_RV_ZFH=ON \\
    -DGGML_RV_ZICBOP=ON \\
    -DGGML_RV_ZIHINTPAUSE=ON \\
    -DGGML_RV_ZBA=ON \\
    -DCMAKE_EXE_LINKER_FLAGS="" \\
    -DCMAKE_SHARED_LINKER_FLAGS="" \\
    -DCMAKE_TOOLCHAIN_FILE="${PWD}/cmake/riscv64-spacemit-linux-gnu-gcc.cmake" \\
    -DCMAKE_INSTALL_PREFIX=build/installed

echo '[container] confirming no static-libstdc++/static-libgcc flags remain cached...'
grep -i 'CMAKE_EXE_LINKER_FLAGS:STRING' build/CMakeCache.txt || echo '[container] (CMAKE_EXE_LINKER_FLAGS not found in cache -- unexpected but not fatal)'

echo '[container] building (incremental -- only changed files recompile after the first run)...'
cmake --build build --parallel "$(nproc)" --config Release

pushd build >/dev/null
make install
popd >/dev/null

echo '[container] verifying output binaries are riscv64...'
file build/bin/llama-bench build/bin/llama-cli 2>&1 || echo '[container] WARNING: file command unavailable or binaries not found at build/bin/ -- continuing to copy step regardless'

mkdir -p /out
cp -v build/bin/llama-bench build/bin/llama-cli /out/

# Safety net: ship any .so llama.cpp itself still produced (shouldn't be any with
# BUILD_SHARED_LIBS=OFF, but don't silently fail if one shows up).
find build/bin -maxdepth 1 -name '*.so*' -exec cp -v {} /out/ \\; 2>/dev/null || true

# Ship libgomp, libstdc++, and libgcc_s -- all now dynamically linked (see NOTE above
# for why libstdc++/libgcc_s must NOT be statically linked into the executables while
# GGML backend .so plugins are loaded via dlopen()). Preserve both the versioned real
# file and any soname symlink so the dynamic linker finds them.
echo '[container] copying libgomp/libstdc++/libgcc_s runtime libs...'
for libpattern in 'libgomp.so*' 'libstdc++.so*' 'libgcc_s.so*'; do
  cp -av "$TC"/riscv64-unknown-linux-gnu/lib/$libpattern /out/ 2>/dev/null || \\
    find "$TC" -name "$libpattern" -exec cp -av {} /out/ \\; 2>/dev/null || \\
    echo "[container] WARNING: could not locate $libpattern under toolchain -- deploy step will need it manually"
done

echo '[container] checking remaining dynamic dependencies (libgomp/libstdc++/libgcc_s expected)...'
"$TC/bin/riscv64-unknown-linux-gnu-readelf" -d build/bin/llama-bench 2>/dev/null | grep -i 'NEEDED' || echo '[container] readelf check unavailable or no NEEDED entries found'
