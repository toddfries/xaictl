#!/bin/bash
# Atomic evidence run: scope-guard + verify-plan with TAP captured to verify-plan.out
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${GROK_GOAL_SCRATCH:?Set GROK_GOAL_SCRATCH to the goal implementer scratch dir}"
mkdir -p "$GROK_GOAL_SCRATCH"

export GROK_GOAL_SCRATCH
# GROK_GOAL_SESSION optional; verify-plan reads active_sessions.json if unset
# Live steps require XAI_API_KEY / XAI_MANAGEMENT_API_KEY pre-exported in environment.

perl "$SCRIPT_DIR/verify-plan.pl" 2>&1 | tee "$GROK_GOAL_SCRATCH/verify-plan.out"
exit "${PIPESTATUS[0]}"