#!/usr/bin/env bash
# tests/w-1-regression.test.sh
# Regression tests for D001: task-description shell injection, and false DONE
# from prose that documents the completion marker.
# W0 should absorb these into the full suite; they must never be deleted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
no()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== D001-A: marker in prose must not complete a worker =="

# A brief that documents the protocol, exactly like every uplift brief does.
cat > "$TMP/brief.md" <<'EOF'
## Reporting
When finished, append `<!-- STATUS: DONE -->` to output.md.
If blocked, append `<!-- STATUS: BLOCKED -->` instead.

## Still working
EOF
[ "$(detect_output_status "$TMP/brief.md")" = "RUNNING" ] \
  && ok "prose mentioning DONE marker -> RUNNING" \
  || no "prose mentioning DONE marker -> $(detect_output_status "$TMP/brief.md") (expected RUNNING)"

# Genuine completion: marker is the last non-empty line.
cp "$TMP/brief.md" "$TMP/done.md"
printf '\n## Result: finished\n\n<!-- STATUS: DONE -->\n\n' >> "$TMP/done.md"
[ "$(detect_output_status "$TMP/done.md")" = "DONE" ] \
  && ok "marker on last non-empty line -> DONE" \
  || no "real DONE marker -> $(detect_output_status "$TMP/done.md") (expected DONE)"

printf '\n<!-- STATUS: BLOCKED -->\n' >> "$TMP/brief.md"
[ "$(detect_output_status "$TMP/brief.md")" = "BLOCKED" ] \
  && ok "BLOCKED marker last -> BLOCKED" || no "BLOCKED not detected"

# Marker followed by trailing prose must NOT count - that ordering bug is why
# claude-code.sh was writing markers the watcher could never see.
cat > "$TMP/trailing.md" <<'EOF'
<!-- STATUS: DONE -->
## Auto-marked DONE
EOF
[ "$(detect_output_status "$TMP/trailing.md")" = "RUNNING" ] \
  && ok "marker followed by prose -> RUNNING (adapters must emit marker last)" \
  || no "marker followed by prose wrongly completed"

echo "== D001-B: task description must never be executed as shell =="

# `date` is the canary: harmless and read-only. If the task text is expanded,
# a timestamp appears where the literal word should be.
CANARY='Docs reference `date` and $(date) inline.'
WD="$TMP/w"; mkdir -p "$WD"
printf '%s\n' "$CANARY" > "$WD/task-desc.txt"

grep -qF 'date' "$WD/task-desc.txt" && ! grep -qE '(UTC|GMT|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}:[0-9]{2}:[0-9]{2})' "$WD/task-desc.txt" \
  && ok "printf %s writes task text verbatim, no expansion" \
  || no "task file shows expansion"

# The generator must not interpolate task text into generated shell at all.
grep -q "cat > \"\$LAUNCH_SH\" <<'LAUNCH_EOF'" "$ROOT/scripts/spawn-worker.sh" \
  && ok "launch.sh generated from a QUOTED heredoc" \
  || no "launch.sh heredoc is unquoted - injection is live"

# The vulnerable form was an UNQUOTED delimiter, which expands the body at
# generation time. With a quoted delimiter, $TASK_DESC inside the body is literal
# text evaluated later in the worker's own shell, which is safe and intended.
grep -q 'cat > "$LAUNCH_SH" <<LAUNCH_EOF' "$ROOT/scripts/spawn-worker.sh" \
  && no "unquoted <<LAUNCH_EOF still present - generation-time expansion is live" \
  || ok "no unquoted launch heredoc remains"

# The other two generators must not carry task text into an unquoted heredoc.
for marker in 'cat > "$OUTPUT_MD" <<EOF' 'cat > "$W_DIR/task.txt" <<EOF'; do
  if awk -v m="$marker" 'index($0,m){f=1;next} /^EOF$/{f=0} f' "$ROOT/scripts/spawn-worker.sh" | grep -q '\$TASK_DESC'; then
    no "\$TASK_DESC interpolated into unquoted heredoc: $marker"
  else
    ok "no \$TASK_DESC in unquoted heredoc: $marker"
  fi
done

for f in "$ROOT/adapters/claude-code.sh" "$ROOT/adapters/generic.sh"; do
  n="$(basename "$f")"
  grep -q 'detect_output_status' "$f" \
    && ok "$n uses shared last-line detection" || no "$n still hand-rolls detection"
  grep -q 'grep -q "STATUS: DONE' "$f" \
    && no "$n still whole-file greps for markers" || ok "$n has no whole-file marker grep"
done

echo
echo "RESULT total=$((PASS+FAIL)) passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
