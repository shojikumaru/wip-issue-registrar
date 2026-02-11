#!/usr/bin/env bash
# dryRun mode: show planned issues without calling GitHub API (FR-003)
# Usage: dry-run.sh <issue-packet.json> [--output <path>]
set -euo pipefail

PACKET="$1"
OUTPUT="${2:-}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 issue-registrar dryRun"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PROJECT=$(jq -r '.project' "$PACKET")
VERSION=$(jq -r '.version' "$PACKET")
EPIC_COUNT=$(jq '.epics | length' "$PACKET")
TOTAL_ISSUES=$(jq '[.epics[].issues[]] | length' "$PACKET")

echo "Project: $PROJECT (schema v$VERSION)"
echo "Epics: $EPIC_COUNT | Issues: $TOTAL_ISSUES"
echo ""

# Collect labels that would be created
LABELS=()

for (( i=0; i<EPIC_COUNT; i++ )); do
  EPIC_ID=$(jq -r ".epics[$i].id" "$PACKET")
  EPIC_TITLE=$(jq -r ".epics[$i].title" "$PACKET")
  ISSUE_COUNT=$(jq ".epics[$i].issues | length" "$PACKET")

  echo "📦 $EPIC_ID: $EPIC_TITLE ($ISSUE_COUNT issues)"
  echo "   Labels: epic:$EPIC_ID"
  LABELS+=("epic:$EPIC_ID")

  for (( j=0; j<ISSUE_COUNT; j++ )); do
    ID=$(jq -r ".epics[$i].issues[$j].id" "$PACKET")
    GOAL=$(jq -r ".epics[$i].issues[$j].goal" "$PACKET")
    MODULE=$(jq -r ".epics[$i].issues[$j].module" "$PACKET")
    PRIORITY=$(jq -r ".epics[$i].issues[$j].priority" "$PACKET")
    DEPS=$(jq -r ".epics[$i].issues[$j].dependsOn | join(\", \")" "$PACKET")

    echo "   ├─ $ID: $GOAL"
    echo "   │  Module: $MODULE | Priority: $PRIORITY"
    if [[ -n "$DEPS" ]]; then
      echo "   │  Depends on: $DEPS"
    fi
    echo "   │  Labels: module:$MODULE, priority:$PRIORITY, oc:issue-id=$ID"

    LABELS+=("module:$MODULE" "priority:$PRIORITY" "oc:issue-id=$ID")
  done
  echo ""
done

# Milestones
MS_COUNT=$(jq '.milestones // [] | length' "$PACKET")
if [[ "$MS_COUNT" -gt 0 ]]; then
  echo "🏁 Milestones ($MS_COUNT):"
  for (( i=0; i<MS_COUNT; i++ )); do
    MS_NAME=$(jq -r ".milestones[$i].name" "$PACKET")
    MS_ISSUES=$(jq -r ".milestones[$i].issues | join(\", \")" "$PACKET")
    echo "   ├─ $MS_NAME: $MS_ISSUES"
  done
  echo ""
fi

# Topological order
echo "📊 Creation order (topological sort):"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/dag.sh"
ORDER=$(dag_topo_sort "$PACKET" 2>/dev/null || echo "(cycle detected - cannot sort)")
echo "$ORDER" | sed 's/^/   /'
echo ""

# Unique labels
UNIQUE_LABELS=$(printf '%s\n' "${LABELS[@]}" | sort -u)
echo "🏷️  Labels to create ($(echo "$UNIQUE_LABELS" | wc -l | tr -d ' ')):"
echo "$UNIQUE_LABELS" | sed 's/^/   /'
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $TOTAL_ISSUES issues to create"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# JSON output if requested
if [[ -n "$OUTPUT" ]]; then
  jq -n \
    --arg project "$PROJECT" \
    --argjson epic_count "$EPIC_COUNT" \
    --argjson issue_count "$TOTAL_ISSUES" \
    --argjson issues "$(jq '[.epics[] | .id as $eid | .title as $etitle | .issues[] | { packetId: .id, epicId: $eid, epicTitle: $etitle, goal: .goal, module: .module, priority: .priority, dependsOn: .dependsOn, action: "create" }]' "$PACKET")" \
    --argjson labels "$(echo "$UNIQUE_LABELS" | jq -R . | jq -s .)" \
    '{
      project: $project,
      epicCount: $epic_count,
      issueCount: $issue_count,
      issues: $issues,
      labelsToCreate: $labels,
      mode: "dryRun"
    }' > "$OUTPUT"
  echo "JSON output written to: $OUTPUT"
fi
