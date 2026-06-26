#!/bin/bash
# Atomic evidence run: scope-guard + verify-plan with TAP captured to verify-plan.out
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="${GROK_GOAL_SCRATCH:-/tmp/grok-goal-a7d760d85190/implementer}"
mkdir -p "$SCRATCH"

export GROK_GOAL_SCRATCH="$SCRATCH"
export GROK_GOAL_SESSION="${GROK_GOAL_SESSION:-019f038d-943e-7ff2-a7bb-999474ec5a6a}"

perl "$SCRIPT_DIR/verify-plan.pl" 2>&1 | tee "$SCRATCH/verify-plan.out"
exit "${PIPESTATUS[0]}"