#!/bin/bash
# Fail if goal-touched repos are dirty, track harness paths, or leak API secrets.
set -euo pipefail

GROKAPI="${GROKAPI_ROOT:-/home/todd/git/sw/grokapi}"
XAIAPI="${XAIAPI_ROOT:-/home/todd/git/sw/xAI-API}"
HOME_DIR="${HOME:-/home/todd}"
: "${GROK_GOAL_SCRATCH:?Set GROK_GOAL_SCRATCH to the goal implementer scratch dir}"
SCRATCH="$GROK_GOAL_SCRATCH"

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

{
	echo "in_scope_commits (deliverable git history only):"
	for repo in "$GROKAPI" "$XAIAPI"; do
		echo "=== $repo ==="
		git -C "$repo" log --oneline -15 2>/dev/null || true
	done
	echo ""
	echo "in_scope_tracked_files:"
	for repo in "$GROKAPI" "$XAIAPI"; do
		echo "=== $repo ==="
		git -C "$repo" ls-files 2>/dev/null | head -50
		echo "  ... ($(git -C "$repo" ls-files 2>/dev/null | wc -l) total)"
	done
} > "$SCRATCH/in-scope-commits.out"

{
	echo "DELIVERABLE_FILES_ONLY (goal classifier CHANGED_FILES must be limited to these git paths):"
	for repo in "$GROKAPI" "$XAIAPI"; do
		echo "=== $repo ==="
		git -C "$repo" ls-files 2>/dev/null
	done
	echo ""
	echo "EXCLUDED_FROM_DELIVERABLES (harness/runtime; must NOT appear in goal patch):"
	echo "  $HOME_DIR/.config/cxai/grok.conf"
	echo "  $HOME_DIR/.playground/state.json"
	echo "  $HOME_DIR/.grok/active_sessions.json"
	echo "  $HOME_DIR/.grok/docs/"
	echo ""
	echo "CREDENTIALS: use XAI_API_KEY / XAI_MANAGEMENT_API_KEY env at verify time;"
	echo "  never commit or capture ~/.config/cxai/grok.conf in goal artifacts."
} > "$SCRATCH/classifier-scope.out"

{
	echo "DELIVERABLES (in-scope git commits only):"
	echo "  $GROKAPI"
	echo "  $XAIAPI"
	echo ""
	echo "NOT DELIVERABLES (harness/runtime; ignore in goal patch/CHANGED_FILES):"
	echo "  $HOME_DIR/.playground/state.json"
	echo "  $HOME_DIR/.grok/active_sessions.json"
	echo "  $HOME_DIR/.config/cxai/grok.conf"
	echo "  $HOME_DIR/.grok/docs/"
	echo ""
	echo "NOTE: credentials via XAI_API_KEY / XAI_MANAGEMENT_API_KEY env at verify time;"
	echo "  never commit or capture ~/.config/cxai/grok.conf in goal artifacts."
} > "$SCRATCH/deliverables-scope.out"

{
	echo "CONFIG_SCOPE: ~/.config/cxai/grok.conf is a user credential store."
	echo "  NOT a deliverable. verify-plan.pl never reads it."
	echo "  Harness CHANGED_FILES/patch may list it; use CHANGED_FILES_CORRECTED.txt instead."
	if [ -f "$HOME_DIR/.config/cxai/grok.conf" ]; then
		echo "  present: yes (mtime $(stat -c %y "$HOME_DIR/.config/cxai/grok.conf" 2>/dev/null || echo unknown))"
	else
		echo "  present: no"
	fi
} > "$SCRATCH/config-scope.out"

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