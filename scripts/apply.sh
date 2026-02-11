#!/usr/bin/env bash
# apply mode: create GitHub Issues from issue-packet.json (FR-004, FR-005, FR-012)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/dag.sh"
source "$SCRIPT_DIR/lib/gh-wrapper.sh"
source "$SCRIPT_DIR/lib/idempotency.sh"
source "$SCRIPT_DIR/lib/state.sh"

PACKET="$1"
REPO="$2"
STATE_PATH="${3:-.issue-registrar-state.json}"
FORCE="${FORCE:-false}"
VERBOSE="${VERBOSE:-false}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" >&2; }
log_warn() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN] $*" >&2; }
log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*" >&2; }

# --- ID map using temp file (bash 3.x compatible) ---
ID_MAP_FILE=$(mktemp)
trap 'rm -f "$ID_MAP_FILE"' EXIT

id_map_set() { echo "$1=$2" >> "$ID_MAP_FILE"; }
id_map_get() { grep "^$1=" "$ID_MAP_FILE" 2>/dev/null | tail -1 | cut -d= -f2; }

# --- Pre-flight ---
log "Checking repo access: $REPO"
if ! gh_check_repo "$REPO"; then
  log_error "Cannot access repository: $REPO"
  exit 2
fi

# --- Initialize state ---
state_init "$STATE_PATH" "$PACKET" || exit 2

# --- Get topological order ---
log "Computing topological order..."
ORDER=$(dag_topo_sort "$PACKET")
if [[ $? -ne 0 ]]; then
  log_error "Cycle detected in dependency DAG"
  exit 2
fi

# Set pending issues in state
# shellcheck disable=SC2086
state_set_pending $ORDER

# Load already-created from state
while IFS= read -r line; do
  pid=$(echo "$line" | jq -r '.packetId')
  ghn=$(echo "$line" | jq -r '.githubNumber')
  id_map_set "$pid" "$ghn"
done < <(jq -c '.created[]' "$STATE_PATH" 2>/dev/null || true)

# --- Ensure labels exist ---
log "Ensuring labels..."
EPIC_COUNT=$(jq '.epics | length' "$PACKET")
ALL_LABELS=""
for (( i=0; i<EPIC_COUNT; i++ )); do
  EPIC_ID=$(jq -r ".epics[$i].id" "$PACKET")
  ALL_LABELS="$ALL_LABELS epic:$EPIC_ID"

  ISSUE_COUNT=$(jq ".epics[$i].issues | length" "$PACKET")
  for (( j=0; j<ISSUE_COUNT; j++ )); do
    MODULE=$(jq -r ".epics[$i].issues[$j].module" "$PACKET")
    PRIORITY=$(jq -r ".epics[$i].issues[$j].priority" "$PACKET")
    ID=$(jq -r ".epics[$i].issues[$j].id" "$PACKET")
    ALL_LABELS="$ALL_LABELS module:$MODULE priority:$PRIORITY oc:issue-id=$ID"
  done
done

for label in $(echo "$ALL_LABELS" | tr ' ' '\n' | sort -u); do
  [[ -z "$label" ]] && continue
  color="ededed"
  [[ "$label" == epic:* ]] && color="1d76db"
  [[ "$label" == module:* ]] && color="0e8a16"
  [[ "$label" == priority:* ]] && color="d93f0b"
  gh_ensure_label "$REPO" "$label" "$color"
done

# --- Ensure milestones exist ---
MS_MAP_FILE=$(mktemp)
MS_COUNT=$(jq '.milestones // [] | length' "$PACKET")
for (( i=0; i<MS_COUNT; i++ )); do
  MS_NAME=$(jq -r ".milestones[$i].name" "$PACKET")
  MS_NUM=$(gh_ensure_milestone "$REPO" "$MS_NAME")
  echo "$MS_NAME=$MS_NUM" >> "$MS_MAP_FILE"
  log "Milestone: $MS_NAME → #$MS_NUM"
done

ms_map_get() { grep "^$1=" "$MS_MAP_FILE" 2>/dev/null | tail -1 | cut -d= -f2; }

# --- Helper: find milestone for an issue ---
find_milestone_for_issue() {
  local issue_id="$1"
  for (( i=0; i<MS_COUNT; i++ )); do
    if jq -e ".milestones[$i].issues | index(\"$issue_id\")" "$PACKET" &>/dev/null; then
      local name
      name=$(jq -r ".milestones[$i].name" "$PACKET")
      ms_map_get "$name"
      return
    fi
  done
}

# --- Helper: find epic info for an issue ---
find_epic_for_issue() {
  local issue_id="$1"
  jq -r ".epics[] | select(.issues[].id == \"$issue_id\") | .id" "$PACKET" | head -1
}

find_epic_title() {
  local epic_id="$1"
  jq -r ".epics[] | select(.id == \"$epic_id\") | .title" "$PACKET"
}

# --- Helper: get issue data ---
get_issue_data() {
  local issue_id="$1"
  jq ".epics[].issues[] | select(.id == \"$issue_id\")" "$PACKET"
}

# --- Create issues in topological order ---
CREATED=0
SKIPPED=0
FAILED=0

for ISSUE_ID in $ORDER; do
  # Skip if already done (state check)
  if state_is_done "$ISSUE_ID"; then
    log "Skipping $ISSUE_ID (already created per state)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Idempotency check (GitHub search)
  existing=$(idempotency_check "$REPO" "$ISSUE_ID" || true)
  if [[ -n "$existing" ]]; then
    log "Skipping $ISSUE_ID (already exists as #$existing — https://github.com/$REPO/issues/$existing)"
    state_record_created "$ISSUE_ID" "$existing" "https://github.com/$REPO/issues/$existing"
    id_map_set "$ISSUE_ID" "$existing"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Get issue data
  DATA=$(get_issue_data "$ISSUE_ID")
  GOAL=$(echo "$DATA" | jq -r '.goal')
  MODULE=$(echo "$DATA" | jq -r '.module')
  PRIORITY=$(echo "$DATA" | jq -r '.priority')
  EPIC_ID=$(find_epic_for_issue "$ISSUE_ID")
  EPIC_TITLE=$(find_epic_title "$EPIC_ID")

  # Build body
  BODY_MD=$(echo "$DATA" | jq -r '.body_md // empty')
  if [[ -z "$BODY_MD" ]]; then
    AC=$(echo "$DATA" | jq -r '.acceptanceCriteria[]' | sed 's/^/- [ ] /')
    IFACES=$(echo "$DATA" | jq -r '.interfaces[]' 2>/dev/null | sed 's/^/- /' || echo "- (none)")
    CONSTR=$(echo "$DATA" | jq -r '.constraints[]' 2>/dev/null | sed 's/^/- /' || echo "- (none)")
    TESTS=$(echo "$DATA" | jq -r '.testPlan[]' | sed 's/^/- /')
    DEPS_IDS=$(echo "$DATA" | jq -r '.dependsOn[]' 2>/dev/null || true)

    DEPS_TEXT=""
    for dep in $DEPS_IDS; do
      dep_num=$(id_map_get "$dep")
      if [[ -n "$dep_num" ]]; then
        DEPS_TEXT="${DEPS_TEXT}Depends on: #${dep_num}
"
      else
        DEPS_TEXT="${DEPS_TEXT}Depends on: ${dep} (not yet created)
"
      fi
    done

    MARKER=$(idempotency_marker "$ISSUE_ID" "$EPIC_ID")

    BODY_MD="## Goal

${GOAL}

## Module

\`${MODULE}\`

## Acceptance Criteria

${AC}

## Interfaces

${IFACES}

## Constraints

${CONSTR}

## Test Plan

${TESTS}
"
    if [[ -n "$DEPS_TEXT" ]]; then
      BODY_MD="${BODY_MD}
## Dependencies

${DEPS_TEXT}"
    fi

    BODY_MD="${BODY_MD}
---

**Epic:** ${EPIC_ID} — ${EPIC_TITLE}
**Priority:** ${PRIORITY}

${MARKER}"
  else
    MARKER=$(idempotency_marker "$ISSUE_ID" "$EPIC_ID")
    BODY_MD="${BODY_MD}

${MARKER}"
  fi

  # Write body to temp file (safe from shell injection)
  BODY_FILE=$(mktemp)
  echo "$BODY_MD" > "$BODY_FILE"

  # Build labels
  LABELS="epic:$EPIC_ID,module:$MODULE,priority:$PRIORITY,oc:issue-id=$ISSUE_ID"

  # Find milestone name for this issue
  MS_TITLE=""
  for (( mi=0; mi<MS_COUNT; mi++ )); do
    if jq -e ".milestones[$mi].issues | index(\"$ISSUE_ID\")" "$PACKET" &>/dev/null; then
      MS_TITLE=$(jq -r ".milestones[$mi].name" "$PACKET")
      break
    fi
  done

  # Create issue
  log "Creating $ISSUE_ID: $GOAL"
  MS_FLAG=""
  if [[ -n "$MS_TITLE" ]]; then
    MS_FLAG="--milestone $MS_TITLE"
  fi

  GH_OUTPUT=$(gh issue create -R "$REPO" --title "$ISSUE_ID: $GOAL" --body-file "$BODY_FILE" --label "$LABELS" $MS_FLAG 2>&1) && rc=0 || rc=$?
  rm -f "$BODY_FILE"

  if [[ $rc -ne 0 ]]; then
    log_error "Failed to create $ISSUE_ID: $GH_OUTPUT"
    state_record_failed "$ISSUE_ID" "$GH_OUTPUT" "true"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Extract issue number from URL
  GH_URL=$(echo "$GH_OUTPUT" | grep -oE 'https://github.com/[^ ]+/issues/[0-9]+' | head -1)
  GH_NUM=$(echo "$GH_URL" | grep -oE '[0-9]+$')

  if [[ -z "$GH_NUM" ]]; then
    log_error "Could not parse issue number from: $GH_OUTPUT"
    state_record_failed "$ISSUE_ID" "Could not parse issue number" "true"
    FAILED=$((FAILED + 1))
    continue
  fi

  state_record_created "$ISSUE_ID" "$GH_NUM" "$GH_URL"
  id_map_set "$ISSUE_ID" "$GH_NUM"
  log "Created $ISSUE_ID → #$GH_NUM ($GH_URL)"
  CREATED=$((CREATED + 1))
done

rm -f "$MS_MAP_FILE"

# --- Summary ---
TOTAL=$((CREATED + SKIPPED + FAILED))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Results"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Created: $CREATED"
echo "⏭️  Skipped: $SKIPPED"
echo "❌ Failed:  $FAILED"
echo "📊 Total:   $TOTAL"
echo ""

# Show created issues
if [[ $CREATED -gt 0 || $SKIPPED -gt 0 ]]; then
  echo "Issues:"
  jq -r '.created[] | "  #\(.githubNumber) \(.packetId) → \(.url)"' "$STATE_PATH"
fi

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "Failed:"
  jq -r '.failed[] | "  \(.packetId): \(.error)"' "$STATE_PATH"
fi

# Exit code
if [[ $FAILED -gt 0 ]]; then
  exit 1  # Partial failure
fi
exit 0
