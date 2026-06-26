#!/bin/bash
# Fail if goal-touched repos are dirty or implementer wrote harness-side docs.
set -euo pipefail

GROKAPI="${GROKAPI_ROOT:-/home/todd/git/sw/grokapi}"
XAIAPI="${XAIAPI_ROOT:-/home/todd/git/sw/xAI-API}"
HOME_DIR="${HOME:-/home/todd}"

for repo in "$GROKAPI" "$XAIAPI"; do
	if [ ! -d "$repo/.git" ]; then
		echo "scope-guard: not a git repo: $repo" >&2
		exit 1
	fi
	dirty=$(git -C "$repo" status --porcelain)
	if [ -n "$dirty" ]; then
		echo "scope-guard: dirty git in $repo" >&2
		echo "$dirty" >&2
		exit 1
	fi
done

# Implementer must not commit harness workspace artifacts into the sw repos.
for repo in "$GROKAPI" "$XAIAPI"; do
	if git -C "$repo" ls-files | grep -qE '\.grok/|\.playground/'; then
		echo "scope-guard: harness paths tracked in $repo" >&2
		exit 1
	fi
done

# Optional: flag implementer-created docs under ~/.grok/docs newer than goal start.
GOAL_START_EPOCH="${GROK_GOAL_START_EPOCH:-0}"
DOCS_DIR="$HOME_DIR/.grok/docs"
if [ "$GOAL_START_EPOCH" -gt 0 ] && [ -d "$DOCS_DIR" ]; then
	while IFS= read -r -d '' f; do
		mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
		if [ "$mtime" -gt "$GOAL_START_EPOCH" ]; then
			echo "scope-guard: implementer doc modified during goal: $f" >&2
			exit 1
		fi
	done < <(find "$DOCS_DIR" -type f -print0 2>/dev/null)
fi

echo "scope-guard: ok"
exit 0