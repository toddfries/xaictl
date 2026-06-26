#!/bin/bash
# Fail if goal-touched repos are dirty, track harness paths, or leak API secrets.
set -euo pipefail

GROKAPI="${GROKAPI_ROOT:-/home/todd/git/sw/grokapi}"
XAIAPI="${XAIAPI_ROOT:-/home/todd/git/sw/xAI-API}"
HOME_DIR="${HOME:-/home/todd}"
SCRATCH="${GROK_GOAL_SCRATCH:-/tmp/grok-goal-a7d760d85190/implementer}"

fail() { echo "scope-guard: $*" >&2; exit 1; }

for repo in "$GROKAPI" "$XAIAPI"; do
	[ -d "$repo/.git" ] || fail "not a git repo: $repo"
	dirty=$(git -C "$repo" status --porcelain)
	[ -z "$dirty" ] || fail "dirty git in $repo: $dirty"
done

# Tracked files must stay inside sw repos (no harness/config paths).
for repo in "$GROKAPI" "$XAIAPI"; do
	tracked=$(git -C "$repo" ls-files)
	echo "$tracked" | grep -qE '\.grok/|\.playground/|grok\.conf' && \
		fail "out-of-scope path tracked in $repo"
	echo "$tracked" | grep -qE '^\.config/' && \
		fail "config path tracked in $repo"
done

# No full xAI bearer tokens in tracked source (redacted ok).
for repo in "$GROKAPI" "$XAIAPI"; do
	while IFS= read -r f; do
		[ -f "$repo/$f" ] || continue
		if grep -qE 'xai-[A-Za-z0-9]{40,}' "$repo/$f" 2>/dev/null; then
			fail "possible API secret in tracked file $repo/$f"
		fi
	done < <(git -C "$repo" ls-files)
done

# Document out-of-scope harness files for auditor (not modified by implementer).
mkdir -p "$SCRATCH"
{
	echo "out_of_scope_paths (goal classifier CHANGED_FILES must NOT include these as implementer deliverables):"
	echo "  $HOME_DIR/.playground/state.json"
	echo "  $HOME_DIR/.grok/docs/"
	echo "  $HOME_DIR/.grok/active_sessions.json"
	echo "  $HOME_DIR/.config/cxai/grok.conf"
	echo ""
	echo "in_scope_repos:"
	echo "  $GROKAPI"
	echo "  $XAIAPI"
} > "$SCRATCH/scope-manifest.txt"

# Optional: flag implementer-created docs under ~/.grok/docs newer than goal start.
GOAL_START_EPOCH="${GROK_GOAL_START_EPOCH:-0}"
DOCS_DIR="$HOME_DIR/.grok/docs"
if [ "$GOAL_START_EPOCH" -gt 0 ] && [ -d "$DOCS_DIR" ]; then
	while IFS= read -r -d '' f; do
		mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
		[ "$mtime" -le "$GOAL_START_EPOCH" ] || fail "implementer doc modified during goal: $f"
	done < <(find "$DOCS_DIR" -type f -print0 2>/dev/null)
fi

echo "scope-guard: ok"
exit 0