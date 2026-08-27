#!/usr/bin/env bash
# install-git-hooks.sh -- install scope-check.sh as both pre-commit and commit-msg.
#
# Git hooks are NOT distributed by clone, so this has to be run once per clone,
# per machine. That is a real limitation: a fresh clone on a new laptop has no
# protection until you run this. GitHub secret scanning + push protection is the
# server-side backstop for that gap -- enable it on every public repo.
#
# Usage:
#   ./scripts/install-git-hooks.sh                              # this repo -> private mode
#   ./scripts/install-git-hooks.sh /path/to/other/clone         # -> public mode (the safe default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOOK="$SCRIPT_DIR/scope-check.sh"

if [ ! -f "$SOURCE_HOOK" ]; then
  echo "FATAL: $SOURCE_HOOK not found." >&2
  exit 1
fi

MODE_FLAG=""
TARGET_ARG=""
for a in "$@"; do
  case "$a" in
    --private|--public) MODE_FLAG="$a" ;;
    *) TARGET_ARG="$a" ;;
  esac
done
TARGET_REPO="${TARGET_ARG:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ ! -d "$TARGET_REPO/.git" ]; then
  echo "FATAL: $TARGET_REPO is not a git clone (no .git directory)." >&2
  exit 1
fi

mkdir -p "$TARGET_REPO/.git/hooks"
for hook in pre-commit commit-msg; do
  cp "$SOURCE_HOOK" "$TARGET_REPO/.git/hooks/$hook"
  chmod +x "$TARGET_REPO/.git/hooks/$hook"
  echo "[install] $TARGET_REPO/.git/hooks/$hook"
done

# Mode selection, in fail-safe order. This file ships inside public repositories,
# so it names no repository, owner or host.
#
#   1. A mode already configured in this clone WINS. Re-running the installer
#      must never quietly downgrade a repo that was already set up.
#   2. Otherwise --private sets private mode. Explicit by design: only a private
#      repo's own documentation tells you to pass it.
#   3. Otherwise public: the strict check. Anything unidentified is treated as
#      publishable, because that is the direction that fails safe.
#
# An earlier revision inferred the mode from whether an argument was passed,
# which selected the weakest setting inside a public clone once this script began
# being copied into other repositories. Infer nothing; require the flag.
EXISTING="$(git -C "$TARGET_REPO" config --get scope.mode || true)"

if [ -n "$EXISTING" ]; then
  MODE_CHOICE="$EXISTING"
  echo "[install] scope.mode = $EXISTING (already configured in this clone; left alone)"
else
  case "${MODE_FLAG:-}" in
    --private) MODE_CHOICE=private ;;
    *)         MODE_CHOICE=public  ;;
  esac
  git -C "$TARGET_REPO" config scope.mode "$MODE_CHOICE"
  if [ "$MODE_CHOICE" = "private" ]; then
    echo "[install] scope.mode = private (tier 1 only: secret material)"
  else
    echo "[install] scope.mode = public (all tiers - the strict check)"
    echo "[install] If and only if this is the private repo, re-run with --private"
    echo "[install] or set it directly:  git -C \"$TARGET_REPO\" config scope.mode private"
  fi
fi

echo "[install] verify: stage a line containing a private hostname or address"
echo "[install]         and confirm the commit is refused."
