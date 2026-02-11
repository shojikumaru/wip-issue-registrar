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
  echo "ERROR: $.  Invalid JSON" >&2
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
for field in epics issues dependencyDAG; do
  if [[ "$(jq "has(\"$field\")" "$PACKET")" != "true" ]]; then
    err "$.$field  Missing required field '$field'"
  fi
done

# v1.1 requires milestones at top level
if [[ "$VERSION" == "1.1" ]]; then
  if [[ "$(jq 'has("milestones")' "$PACKET")" != "true" ]]; then
    err "$.milestones  Missing required field 'milestones' (required in v1.1)"
  fi
fi

# --- 5. Validate epics ---
EPIC_COUNT=$(jq '.epics // [] | length' "$PACKET")
for (( i=0; i<EPIC_COUNT; i++ )); do
  PREFIX="$.epics[$i]"
  
  # Required fields
  for field in id title; do
    val=$(jq -r ".epics[$i].$field // empty" "$PACKET")
    if [[ -z "$val" ]]; then
      err "$PREFIX.$field  Missing required field '$field'"
    fi
  done
  
  # ID format: EPIC-xxx
  EPIC_ID=$(jq -r ".epics[$i].id // empty" "$PACKET")
  if [[ -n "$EPIC_ID" ]] && ! echo "$EPIC_ID" | grep -qE '^EPIC-[0-9]+$'; then
    err "$PREFIX.id  Invalid ID format '$EPIC_ID' (expected EPIC-xxx)"
  fi
done

# --- 6. Validate issues ---
ISSUE_COUNT=$(jq '.issues // [] | length' "$PACKET")
REQUIRED_ISSUE_FIELDS=(id title epicId goal acceptanceCriteria)

for (( i=0; i<ISSUE_COUNT; i++ )); do
  PREFIX="$.issues[$i]"
  
  for field in "${REQUIRED_ISSUE_FIELDS[@]}"; do
    val=$(jq -r ".issues[$i].$field // empty" "$PACKET")
    if [[ -z "$val" ]]; then
      # acceptanceCriteria is an array — check differently
      if [[ "$field" == "acceptanceCriteria" ]]; then
        ac_len=$(jq ".issues[$i].acceptanceCriteria // null | length" "$PACKET")
        if [[ "$ac_len" == "0" || "$ac_len" == "null" ]]; then
          err "$PREFIX.$field  Missing required field '$field'"
        fi
      else
        err "$PREFIX.$field  Missing required field '$field'"
      fi
    fi
  done
  
  # v1.1 requires body_md on each issue
  if [[ "$VERSION" == "1.1" ]]; then
    val=$(jq -r ".issues[$i].body_md // empty" "$PACKET")
    if [[ -z "$val" ]]; then
      err "$PREFIX.body_md  Missing required field 'body_md' (required in v1.1)"
    fi
  fi
  
  # ID format: ISSUE-xxx
  ISSUE_ID=$(jq -r ".issues[$i].id // empty" "$PACKET")
  if [[ -n "$ISSUE_ID" ]] && ! echo "$ISSUE_ID" | grep -qE '^ISSUE-[0-9]+$'; then
    err "$PREFIX.id  Invalid ID format '$ISSUE_ID' (expected ISSUE-xxx)"
  fi
done

# --- 7. Report ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Validation failed with ${#ERRORS[@]} error(s):" >&2
  for e in "${ERRORS[@]}"; do
    echo "  ERROR: $e" >&2
  done
  exit 1
fi

echo "Validation passed (schema v${VERSION})"
exit 0
