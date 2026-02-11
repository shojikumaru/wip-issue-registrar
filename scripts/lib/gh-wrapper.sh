#!/usr/bin/env bash
# gh CLI wrapper with retry + rate limit handling (NFR-001, NFR-002)

GH_RETRY_MAX=${GH_RETRY_MAX:-3}
GH_RETRY_DELAY=${GH_RETRY_DELAY:-2}
GH_INTERVAL=${GH_INTERVAL:-1}

# Execute gh command with retry
# Usage: gh_exec <gh args...>
# Returns: gh exit code, stdout captured
gh_exec() {
  local attempt=0
  local delay=$GH_RETRY_DELAY
  local output=""
  local rc=0

  while (( attempt < GH_RETRY_MAX )); do
    attempt=$((attempt + 1))
    output=$(gh "$@" 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
      echo "$output"
      sleep "$GH_INTERVAL"
      return 0
    fi

    # Check for rate limit
    if echo "$output" | grep -qi "rate limit\|403.*rate\|429"; then
      echo "[WARN] Rate limit hit, waiting 60s..." >&2
      sleep 60
      continue
    fi

    # Auth/permission errors - don't retry
    if echo "$output" | grep -qi "401\|403.*forbidden\|authentication"; then
      echo "[ERROR] Auth/permission error: $output" >&2
      return 1
    fi

    # 404 - don't retry
    if echo "$output" | grep -qi "404\|not found"; then
      echo "[ERROR] Not found: $output" >&2
      return 1
    fi

    # 422 validation - don't retry
    if echo "$output" | grep -qi "422\|validation"; then
      echo "[ERROR] Validation error: $output" >&2
      return 1
    fi

    # Server error - retry with backoff
    if (( attempt < GH_RETRY_MAX )); then
      echo "[WARN] Attempt $attempt failed, retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  echo "[ERROR] Failed after $GH_RETRY_MAX attempts: $output" >&2
  return 1
}

# Check repo access
# Usage: gh_check_repo <owner/repo>
gh_check_repo() {
  local repo="$1"
  if ! gh repo view "$repo" --json name -q '.name' &>/dev/null; then
    echo "[ERROR] Cannot access repository: $repo" >&2
    return 1
  fi
  return 0
}

# Ensure label exists, create if not
# Usage: gh_ensure_label <owner/repo> <label-name> [color]
gh_ensure_label() {
  local repo="$1" label="$2" color="${3:-ededed}"

  if gh label list -R "$repo" --json name -q ".[].name" 2>/dev/null | grep -qx "$label"; then
    return 0  # Already exists
  fi

  gh_exec label create "$label" -R "$repo" --color "$color" --force &>/dev/null
}

# Ensure milestone exists, create if not
# Usage: gh_ensure_milestone <owner/repo> <milestone-name>
# Output: milestone number
gh_ensure_milestone() {
  local repo="$1" name="$2"

  # Check if exists
  local num
  num=$(gh api "repos/$repo/milestones" --jq ".[] | select(.title==\"$name\") | .number" 2>/dev/null)
  if [[ -n "$num" ]]; then
    echo "$num"
    return 0
  fi

  # Create
  num=$(gh api "repos/$repo/milestones" -f "title=$name" --jq '.number' 2>/dev/null)
  echo "$num"
}
