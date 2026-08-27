#!/usr/bin/env bash
# scope-check.sh -- block commits, and commit messages, that leak private lab
# details or secret material.
#
# Installed as BOTH .git/hooks/pre-commit and .git/hooks/commit-msg by
# install-git-hooks.sh. Git passes the message file path to commit-msg and
# nothing to pre-commit, which is how this one script tells them apart.
#
# WHY THIS EXISTS
# Reviewing a change cannot catch a scope error, because the reviewer inherits
# the author's framing -- and the author, by definition, believed the content
# belonged here. So this check is deliberately dumb. It is a fixed-string match.
# It does not care about intent, justification, or how good the reasoning sounds.
# That is the point: it fires regardless of how convinced the author is.
#
# It also scans the commit message and the staged filenames, not just the diff.
# A clean patch with a revealing message, or a revealing filename, still leaks.
#
# THREE TIERS, because the previous two-tier version cried wolf
#   Tier 1  secret material          blocked in BOTH modes
#   Tier 2  words describing secrets  blocked in public mode only
#   Tier 3  private lab identifiers   blocked in public mode only
# Tier 2 exists because words that merely DESCRIBE secrets are normal, necessary
# content in a private repo -- measured there at 5 and 6 occurrences for two of
# them. Blocking those in the private repo guaranteed false positives, and a
# control that cries wolf trains the bypass habit, which is worse than no
# control at all.
#
# MODES
#   public  (default) -- all three tiers. Use in any repo that is or may become public.
#   private           -- tier 1 only.
# Set per clone with:  git config scope.mode private
#
# BYPASS
# Intentionally awkward: SCOPE_CHECK_SKIP=1 git commit ...
# If you find yourself using it, stop and ask whether the file belongs in this repo.

set -uo pipefail

if [ "${SCOPE_CHECK_SKIP:-0}" = "1" ]; then
  echo "[scope-check] SKIPPED via SCOPE_CHECK_SKIP=1 -- you are on your own."
  exit 0
fi

MODE="$(git config --get scope.mode || echo public)"

# ---- Tier 1: actual secret material. Blocked in BOTH modes. ------------------
# Tokens are never committed anywhere, not even to the private repo -- prompt for
# them at runtime, or keep them in a gitignored local file.
SECRET_PATTERNS=(
  'BEGIN OPENSSH PRIVATE KEY'
  'BEGIN RSA PRIVATE KEY'
  'BEGIN EC PRIVATE KEY'
  'BEGIN PRIVATE KEY'
)

# ---- Tier 1b: secrets identified by a PREFIX. Blocked in BOTH modes. ---------
# These must be regexes, not fixed strings. A bare 'ghp_' or 'nano-kvm-token='
# appears legitimately in prose that DOCUMENTS the control, and a fixed-string
# match on the prefix blocked this script and its own documentation from ever
# being committed. Requiring a
# plausible value after the prefix distinguishes a real token from the name of a
# token, which is the whole distinction tier 2 exists to make.
SECRET_REGEXES=(
  'tskey-[A-Za-z0-9][A-Za-z0-9-]{9,}'   # real keys are tskey-auth-... / tskey-api-...: hyphens inside
  'ghp_[A-Za-z0-9]{20,}'
  'gho_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'nano-kvm-token=[A-Za-z0-9._-]{4,}'   # the cookie ASSIGNED, not prose about it
)

# ---- Tiers 2 and 3 are LOADED, not embedded. ---------------------------------
# The private-identifier list used to live in this file. That made the guard
# itself unpublishable: shipping it into a public repo would publish the complete
# inventory of every hostname, subnet, surname stem and MAC address it exists to
# keep out -- in one list, helpfully labelled as the private things. And the
# guard could not catch that, because it deliberately does not scan itself.
#
# So: this script is generic and safe to publish. The list is private data and
# lives in the private repo (scripts/private-patterns), or anywhere pointed to by
# SCOPE_PATTERNS_FILE, or ~/.config/scope-check/patterns for machines that keep
# it outside a clone.
#
# A public clone WITHOUT the list still enforces tier 1 -- real secret material,
# which is what a third-party contributor needs -- and says loudly that tiers 2
# and 3 are inactive. It does not fail closed: a stranger who clones this repo
# has no list, needs none, and must not be blocked from committing.
WORD_PATTERNS=()
PRIVATE_PATTERNS=()
PRIVATE_REGEXES=()

PATTERNS_FILE=""
for candidate in \
    "${SCOPE_PATTERNS_FILE:-}" \
    "$(git rev-parse --show-toplevel 2>/dev/null)/scripts/private-patterns" \
    "$HOME/.config/scope-check/patterns"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then PATTERNS_FILE="$candidate"; break; fi
done

if [ -n "$PATTERNS_FILE" ]; then
  section=""
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      '[words]') section=words; continue ;;
      '[fixed]') section=fixed; continue ;;
      '[regex]') section=regex; continue ;;
    esac
    case "$section" in
      words) WORD_PATTERNS+=("$line") ;;
      fixed) PRIVATE_PATTERNS+=("$line") ;;
      regex) PRIVATE_REGEXES+=("$line") ;;
    esac
  done < "$PATTERNS_FILE"
fi

# ---- What are we scanning? --------------------------------------------------
# commit-msg receives the message file as $1; pre-commit receives nothing.
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
  WHAT="commit message"
  CONTENT="$(cat -- "$1")"
else
  WHAT="staged changes"
  # Added lines, plus staged path names -- a file named after a private host
  # leaks in the filename even when its contents are clean, and binary diffs
  # have no scannable content at all.
  # The hook's own source necessarily contains every pattern it looks for, so
  # scanning it means the control can never be committed or amended. Excluded by
  # basename so this holds wherever a clone keeps it. Narrow, deliberate hole:
  # a file named scope-check.sh is not scanned, so do not name anything else that.
  SELF=':(exclude,glob)**/scope-check.sh'
  CONTENT="$(
    { git diff --cached -U0 -- . "$SELF" | grep '^+' | grep -v '^+++'
      git diff --cached --name-only -- . "$SELF"
    } 2>/dev/null || true
  )"
fi

if [ -z "$CONTENT" ]; then
  exit 0
fi

FOUND=0

banner() {
  if [ "$FOUND" -eq 0 ]; then
    echo ""
    echo "============================================================="
    echo " BLOCKED by scope-check  (mode: $MODE, scanning: $WHAT)"
    echo "============================================================="
  fi
  FOUND=1
}

check_fixed() {
  local label="$1"; shift
  local pat hits
  for pat in "$@"; do
    hits="$(printf '%s\n' "$CONTENT" | grep -F -i -- "$pat" || true)"
    if [ -n "$hits" ]; then
      banner
      echo ""
      echo "  [$label] matched: $pat"
      printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    fi
  done
}

check_regex() {
  local label="$1"; shift
  local re hits
  for re in "$@"; do
    hits="$(printf '%s\n' "$CONTENT" | grep -E -i -- "$re" || true)"
    if [ -n "$hits" ]; then
      banner
      echo ""
      echo "  [$label] matched regex: $re"
      printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    fi
  done
}

check_fixed "secret" "${SECRET_PATTERNS[@]}"
check_regex "secret" "${SECRET_REGEXES[@]}"

if [ "$MODE" != "private" ]; then
  if [ "${#PRIVATE_PATTERNS[@]}" -eq 0 ]; then
    echo "[scope-check] NOTE: no private-pattern list found, so only tier 1 (secret" >&2
    echo "[scope-check]       material) is active. Tiers 2-3 -- hostnames, addresses," >&2
    echo "[scope-check]       lab identifiers -- are NOT being checked." >&2
    echo "[scope-check]       Point SCOPE_PATTERNS_FILE at a list, or install one at" >&2
    echo "[scope-check]       ~/.config/scope-check/patterns, if this machine should have one." >&2
  else
    check_fixed "secret-adjacent" "${WORD_PATTERNS[@]}"
    check_fixed "private-detail"  "${PRIVATE_PATTERNS[@]}"
    check_regex "private-detail"  "${PRIVATE_REGEXES[@]}"
  fi
fi

if [ "$FOUND" -ne 0 ]; then
  echo ""
  echo "-------------------------------------------------------------"
  echo "This looks like it does not belong in this repository."
  echo "Ask: would this text make sense, and be useful, to a stranger who"
  echo "does not own this lab and never will? If no, it does not belong"
  echo "in a public repo."
  echo ""
  echo "If this repo IS the private one:  git config scope.mode private"
  echo "-------------------------------------------------------------"
  echo ""
  exit 1
fi

exit 0
