#!/usr/bin/env bash
# tests/lib/fake-adapter.sh - deterministic adapter for tests. No agent, no network.
#
# Contract (identical to adapters/generic.sh):
#   <worker-id> <worktree> <task_type> <task_desc> <output.md> <manifest.json>
#
# Behaviour is chosen by FAKE_ADAPTER_MODE, or by a token in the task text so a
# test can drive a worker without controlling the adapter's environment:
#
#   done      (default) produce real work, then mark DONE
#   blocked   produce work, then mark BLOCKED
#   failed    produce work, then mark FAILED
#   silent    produce work but write NO marker    (tests the no-marker path)
#   nowork    write nothing at all, exit 0        (tests the D002 evidence gate)
#   crash     exit non-zero                       (tests the failure path)
#   hang      sleep until killed                  (tests stale/dead detection)
#
# Marker is always the LAST non-empty line, per D001.
set -uo pipefail

WORKER_ID="${1:-unknown}"
WORKTREE_PATH="${2:-$(pwd)}"
TASK_TYPE="${3:-ship}"
TASK_DESC="${4:-}"
OUTPUT_PATH="${5:-}"
MANIFEST_PATH="${6:-}"

MODE="${FAKE_ADAPTER_MODE:-}"
if [ -z "$MODE" ]; then
  case "$TASK_DESC" in
    *FAKE:blocked*) MODE=blocked ;;
    *FAKE:failed*)  MODE=failed  ;;
    *FAKE:silent*)  MODE=silent  ;;
    *FAKE:nowork*)  MODE=nowork  ;;
    *FAKE:crash*)   MODE=crash   ;;
    *FAKE:hang*)    MODE=hang    ;;
    *)              MODE=done    ;;
  esac
fi

say() { [ -n "$OUTPUT_PATH" ] && echo "$@" >> "$OUTPUT_PATH"; echo "$@"; }

say ""
say "## Adapter: fake ($MODE)"

case "$MODE" in
  nowork) exit 0 ;;
  crash)  say "## Failed: simulated crash"; exit 7 ;;
  hang)   say "hanging"; sleep 3600; exit 0 ;;
esac

# Produce genuine evidence of work so the D002 gate is satisfied.
cd "$WORKTREE_PATH" || exit 1
printf 'work by %s\n' "$WORKER_ID" > "FAKE_WORK_${WORKER_ID}.txt"
if [ "$TASK_TYPE" = "ship" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  git add -A >/dev/null 2>&1
  git -c user.email=test@example.invalid -c user.name="Fake Adapter" \
      commit -qm "crew($WORKER_ID): fake work" >/dev/null 2>&1
fi

case "$MODE" in
  silent)  say "## Result: work done, marker deliberately omitted" ;;
  blocked) say ""; say "## Blocked: simulated"; say ""; say "<!-- STATUS: BLOCKED -->" ;;
  failed)  say ""; say "## Failed: simulated";  say ""; say "<!-- STATUS: FAILED -->"  ;;
  *)       say ""; say "## Result: fake work complete"; say ""; say "<!-- STATUS: DONE -->" ;;
esac

exit 0
