#!/usr/bin/env bash
# FR-001: issue-packet.json input validation
# Usage: scripts/validate.sh [path-to-issue-packet.json]
set -euo pipefail

PACKET="${1:-issue-packet.json}"
ERRORS=()

err() { ERRORS+=("$1"); }

# --- 1. File existence ---
if [[ ! -f "$PACKET" ]]; then
  echo "ERROR: File not found: $PACKET" >&2
  exit 1
fi

# --- 2. Valid JSON ---
if ! jq empty "$PACKET" 2>/dev/null; then
  echo "ERROR: Invalid JSON: $PACKET" >&2
  exit 1
fi

# --- 3. Version field ---
VERSION=$(jq -r '.version // empty' "$PACKET")
if [[ -z "$VERSION" ]]; then
  err "$.version  Missing required field 'version'"
elif [[ "$VERSION" != "1.0" && "$VERSION" != "1.1" ]]; then
  err "$.version  Unsupported version '$VERSION' (expected '1.0' or '1.1')"
fi

# --- 4. Top-level required fields ---
for field in project epics dependencyDAG; do
  if [[ "$(jq "has(\"$field\")" "$PACKET")" != "true" ]]; then
    err "$.$field  Missing required field '$field'"
  fi
done

# project must not be empty
PROJECT=$(jq -r '.project // empty' "$PACKET")
if [[ -z "$PROJECT" ]]; then
  err "$.project  Field must not be empty"
fi

# --- 5. dependencyDAG sub-fields ---
if [[ "$(jq '.dependencyDAG | has("nodes")' "$PACKET" 2>/dev/null)" != "true" ]]; then
  err "$.dependencyDAG.nodes  Missing required field"
fi
if [[ "$(jq '.dependencyDAG | has("edges")' "$PACKET" 2>/dev/null)" != "true" ]]; then
  err "$.dependencyDAG.edges  Missing required field"
fi

# --- 6. Validate epics and nested issues ---
EPIC_COUNT=$(jq '.epics // [] | length' "$PACKET")
if [[ "$EPIC_COUNT" -eq 0 ]]; then
  err "$.epics  Must have at least 1 epic"
fi

# Collect all IDs for DAG validation later
ALL_IDS=()

for (( i=0; i<EPIC_COUNT; i++ )); do
  EP="$.epics[$i]"

  # Required epic fields
  for field in id title modules issues; do
    if [[ "$(jq ".epics[$i] | has(\"$field\")" "$PACKET")" != "true" ]]; then
      err "$EP.$field  Missing required field"
    fi
  done

  # Epic ID format
  EPIC_ID=$(jq -r ".epics[$i].id // empty" "$PACKET")
  if [[ -n "$EPIC_ID" ]]; then
    ALL_IDS+=("$EPIC_ID")
    if ! echo "$EPIC_ID" | grep -qE '^EPIC-[0-9]{3}$'; then
      err "$EP.id  Invalid format '$EPIC_ID' (expected EPIC-NNN)"
    fi
  fi

  # Validate nested issues
  ISSUE_COUNT=$(jq ".epics[$i].issues // [] | length" "$PACKET")
  if [[ "$ISSUE_COUNT" -eq 0 ]]; then
    err "$EP.issues  Must have at least 1 issue"
  fi

  for (( j=0; j<ISSUE_COUNT; j++ )); do
    IS="$EP.issues[$j]"

    # Required issue fields
    for field in id module goal acceptanceCriteria interfaces constraints testPlan dependsOn priority; do
      if [[ "$(jq ".epics[$i].issues[$j] | has(\"$field\")" "$PACKET")" != "true" ]]; then
        err "$IS.$field  Missing required field"
      fi
    done

    # Issue ID format
    ISSUE_ID=$(jq -r ".epics[$i].issues[$j].id // empty" "$PACKET")
    if [[ -n "$ISSUE_ID" ]]; then
      ALL_IDS+=("$ISSUE_ID")
      if ! echo "$ISSUE_ID" | grep -qE '^ISSUE-[0-9]{3}$'; then
        err "$IS.id  Invalid format '$ISSUE_ID' (expected ISSUE-NNN)"
      fi
    fi

    # Priority enum
    PRIORITY=$(jq -r ".epics[$i].issues[$j].priority // empty" "$PACKET")
    if [[ -n "$PRIORITY" ]] && [[ "$PRIORITY" != "high" && "$PRIORITY" != "medium" && "$PRIORITY" != "low" ]]; then
      err "$IS.priority  Invalid value '$PRIORITY' (expected high|medium|low)"
    fi

    # Goal non-empty
    GOAL=$(jq -r ".epics[$i].issues[$j].goal // empty" "$PACKET")
    if [[ -z "$GOAL" ]]; then
      err "$IS.goal  Must not be empty"
    fi

    # AC at least 1 item
    AC_LEN=$(jq ".epics[$i].issues[$j].acceptanceCriteria // [] | length" "$PACKET")
    if [[ "$AC_LEN" -eq 0 ]]; then
      err "$IS.acceptanceCriteria  Must have at least 1 item"
    fi

    # testPlan at least 1 item
    TP_LEN=$(jq ".epics[$i].issues[$j].testPlan // [] | length" "$PACKET")
    if [[ "$TP_LEN" -eq 0 ]]; then
      err "$IS.testPlan  Must have at least 1 item"
    fi
  done
done

# --- 7. dependsOn reference validation ---
# Collect all issue IDs only (not epic IDs)
ISSUE_IDS=()
for (( i=0; i<EPIC_COUNT; i++ )); do
  ISSUE_COUNT=$(jq ".epics[$i].issues // [] | length" "$PACKET")
  for (( j=0; j<ISSUE_COUNT; j++ )); do
    ISSUE_IDS+=("$(jq -r ".epics[$i].issues[$j].id // empty" "$PACKET")")
  done
done

for (( i=0; i<EPIC_COUNT; i++ )); do
  ISSUE_COUNT=$(jq ".epics[$i].issues // [] | length" "$PACKET")
  for (( j=0; j<ISSUE_COUNT; j++ )); do
    IS="$.epics[$i].issues[$j]"
    DEP_COUNT=$(jq ".epics[$i].issues[$j].dependsOn // [] | length" "$PACKET")
    for (( k=0; k<DEP_COUNT; k++ )); do
      DEP=$(jq -r ".epics[$i].issues[$j].dependsOn[$k]" "$PACKET")
      found=false
      for iid in "${ISSUE_IDS[@]}"; do
        [[ "$iid" == "$DEP" ]] && found=true && break
      done
      if [[ "$found" == "false" ]]; then
        err "$IS.dependsOn[$k]  References unknown issue: '$DEP'"
      fi
    done
  done
done

# --- 8. DAG edge references ---
EDGE_COUNT=$(jq '.dependencyDAG.edges // [] | length' "$PACKET")
for (( i=0; i<EDGE_COUNT; i++ )); do
  FROM=$(jq -r ".dependencyDAG.edges[$i][0]" "$PACKET")
  TO=$(jq -r ".dependencyDAG.edges[$i][1]" "$PACKET")

  found_from=false
  found_to=false
  for id in "${ALL_IDS[@]}"; do
    [[ "$id" == "$FROM" ]] && found_from=true
    [[ "$id" == "$TO" ]] && found_to=true
  done

  if [[ "$found_from" == "false" ]]; then
    echo "[WARN]  DAG edge references unknown node: '$FROM'" >&2
  fi
  if [[ "$found_to" == "false" ]]; then
    echo "[WARN]  DAG edge references unknown node: '$TO'" >&2
  fi
done

# --- 9. Duplicate ID check ---
DUP=$(printf '%s\n' "${ALL_IDS[@]}" | sort | uniq -d | head -1)
if [[ -n "$DUP" ]]; then
  err "Duplicate ID found: $DUP"
fi

# --- 10. Report ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Validation failed with ${#ERRORS[@]} error(s):" >&2
  for e in "${ERRORS[@]}"; do
    echo "  ERROR: $e" >&2
  done
  exit 1
fi

TOTAL_ISSUES=$(jq '[.epics[].issues[]] | length' "$PACKET")
echo "Validation passed ✅ (version=$VERSION, epics=$EPIC_COUNT, issues=$TOTAL_ISSUES)"
exit 0
