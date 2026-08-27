# SpacemiT K3 llama.cpp Builds — Claude Context

This repository builds and publishes **IME-enabled `llama.cpp` binaries for the SpacemiT K3
SoC** (X100 / A100 clusters), cross-compiled in Docker with SpacemiT's own toolchain. That is its
entire scope: one target, one piece of software.

It is public because the RISC-V software ecosystem is not fully matured — working builds for this
hardware are hard to come by, and the stock packages that do exist do not exercise the SoC's matrix
instructions at all. Publishing them advances development on the architecture for everyone with
this board.

## Where the detail lives

`README.md` is the authoritative description — read it before changing
anything, especially **Fix history** and **If you are debugging this pipeline again, read this
first**, which exist because this pipeline has broken in non-obvious ways more than once.

## The one thing that makes this project worth existing

Stock GCC cannot assemble the IME matrix instructions (`vmadot` — the assembler rejects them with
`extension 'xsmtvdotii' required`), so a distribution-packaged `llama.cpp` silently benchmarks the
*compiler* rather than the hardware. The measured gap between a stock build and an IME-enabled one
on the same silicon is roughly **70x**. Any performance claim made about this hardware is
meaningless without stating how the binary was built.

Corollary for anything measured here: **state the build configuration alongside the number**, and
treat a surprising result as a possible instrumentation error before treating it as a finding.

## Conventions

- **No machine-specific values in the repository.** No hostnames, IP addresses, usernames, SSH
  details, network layout or hardware inventory — in files, filenames, *or commit messages*. Real
  target values go in `.env`, which is gitignored; `.env.example` ships word placeholders, never
  sample addresses.
- **Never commit tokens, keys or credentials.**
- **Install the git hooks in every clone, on every machine:** `./scripts/install-git-hooks.sh`.
  Git does not distribute hooks, so a fresh clone has no protection until you run it. They check
  staged content, staged filenames and the commit message.
- **Bump `SCRIPT_VERSION`** on every edit to the build script, so a log can be traced to the code
  that produced it.
- **Verify current-state facts by search before asserting.** The RISC-V toolchain landscape moves
  monthly, and vendor documentation lags it.

## Working style

The maintainer is technically skilled but time-constrained. Produce runnable commands, scripts and
commits rather than reading assignments. Surface caveats before building, not after.
