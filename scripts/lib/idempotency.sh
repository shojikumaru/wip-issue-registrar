#!/usr/bin/env bash
# Idempotency checks (FR-006)

# Check if an issue with given packet ID already exists
# Primary: label oc:issue-id=<ISSUE-ID>
# Fallback: body HTML comment <!-- issue-registrar:v1 {"packetId":"<ISSUE-ID>"} -->
# Searches open + closed issues
# Usage: idempotency_check <owner/repo> <ISSUE-ID>
# Output: GitHub issue number if found, empty if not
idempotency_check() {
  local repo="$1" packet_id="$2"

  # Primary: label search (includes closed)
  local label="oc:issue-id=${packet_id}"
  local num
  num=$(gh issue list -R "$repo" --label "$label" --state all --json number -q '.[0].number' 2>/dev/null)
  if [[ -n "$num" ]]; then
    echo "$num"
    return 0
  fi

  # Fallback: body search
  num=$(gh issue list -R "$repo" --search "issue-registrar:v1 ${packet_id} in:body" --state all --json number -q '.[0].number' 2>/dev/null)
  if [[ -n "$num" ]]; then
    echo "$num"
    return 0
  fi

  return 1  # Not found
}

# Generate the metadata comment to embed in issue body
# Usage: idempotency_marker <ISSUE-ID> <EPIC-ID>
idempotency_marker() {
  local packet_id="$1" epic_id="$2"
  echo "<!-- issue-registrar:v1 {\"packetId\":\"${packet_id}\",\"epicId\":\"${epic_id}\",\"version\":\"1.1\"} -->"
}
