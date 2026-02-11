#!/usr/bin/env bash
# State file management for partial failure recovery (FR-009)

STATE_FILE=""

# Initialize or load state
# Usage: state_init <state-file-path> <packet-file>
state_init() {
  STATE_FILE="$1"
  local packet_file="$2"

  local packet_hash
  packet_hash=$(md5sum "$packet_file" 2>/dev/null | cut -d' ' -f1 || md5 -q "$packet_file" 2>/dev/null)

  if [[ -f "$STATE_FILE" ]]; then
    local existing_hash
    existing_hash=$(jq -r '.packetHash // empty' "$STATE_FILE")
    if [[ -n "$existing_hash" && "$existing_hash" != "$packet_hash" ]]; then
      echo "[WARN] Packet file changed since last run (hash mismatch)" >&2
      if [[ "${FORCE:-false}" != "true" ]]; then
        echo "[ERROR] Use --force to continue with changed packet" >&2
        return 1
      fi
    fi
    return 0
  fi

  # Create new state
  jq -n \
    --arg hash "$packet_hash" \
    --arg file "$packet_file" \
    '{
      version: "1.0",
      packetFile: $file,
      packetHash: $hash,
      startedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      updatedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      created: [],
      failed: [],
      pending: [],
      labels: { created: [], existed: [] },
      milestones: { created: [], existed: [] }
    }' > "$STATE_FILE"
}

# Record a created issue
# Usage: state_record_created <packetId> <githubNumber> <url>
state_record_created() {
  local packet_id="$1" gh_number="$2" url="$3"
  local tmp=$(mktemp)
  jq \
    --arg id "$packet_id" \
    --argjson num "$gh_number" \
    --arg url "$url" \
    '.created += [{ packetId: $id, githubNumber: $num, url: $url }] |
     .pending = (.pending | map(select(. != $id))) |
     .updatedAt = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Record a failed issue
# Usage: state_record_failed <packetId> <error> <retryable>
state_record_failed() {
  local packet_id="$1" error="$2" retryable="${3:-true}"
  local tmp=$(mktemp)
  jq \
    --arg id "$packet_id" \
    --arg err "$error" \
    --argjson retry "$retryable" \
    '.failed += [{ packetId: $id, error: $err, retryable: $retry }] |
     .pending = (.pending | map(select(. != $id))) |
     .updatedAt = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Check if issue is already created or should be skipped
# Usage: state_is_done <packetId>
# Returns: 0 if done, 1 if not
state_is_done() {
  local packet_id="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    return 1
  fi
  local found
  found=$(jq -r --arg id "$packet_id" '.created[] | select(.packetId == $id) | .packetId' "$STATE_FILE" 2>/dev/null)
  [[ -n "$found" ]]
}

# Set pending issues list
# Usage: state_set_pending <id1> <id2> ...
state_set_pending() {
  local ids=("$@")
  local json_array
  json_array=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)
  local tmp=$(mktemp)
  jq --argjson pending "$json_array" '.pending = $pending' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Print summary
state_summary() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No state file"
    return
  fi
  local created failed pending
  created=$(jq '.created | length' "$STATE_FILE")
  failed=$(jq '.failed | length' "$STATE_FILE")
  pending=$(jq '.pending | length' "$STATE_FILE")
  echo "✅ Created: $created | ❌ Failed: $failed | ⏳ Pending: $pending"
}
