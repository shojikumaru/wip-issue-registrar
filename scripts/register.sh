#!/usr/bin/env bash
# issue-registrar: Register GitHub Issues from issue-packet.json
# Usage: register.sh <issue-packet.json> [options]
#   --mode dryRun|apply    (default: dryRun)
#   --repo owner/repo      (default: from git remote)
#   --output <path>        dryRun JSON output path
#   --state <path>         State file path (default: .issue-registrar-state.json)
#   --force                Continue even if packet hash changed
#   --cleanup              Delete state file after completion
#   --verbose              Verbose logging
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse args ---
PACKET=""
MODE="dryRun"
REPO=""
OUTPUT=""
STATE_PATH=".issue-registrar-state.json"
export FORCE="false"
export VERBOSE="false"
CLEANUP="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)    MODE="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --state)   STATE_PATH="$2"; shift 2 ;;
    --force)   FORCE="true"; shift ;;
    --cleanup) CLEANUP="true"; shift ;;
    --verbose) VERBOSE="true"; shift ;;
    -h|--help)
      echo "Usage: register.sh <issue-packet.json> [options]"
      echo "  --mode dryRun|apply    Mode (default: dryRun)"
      echo "  --repo owner/repo      Target repository"
      echo "  --output <path>        dryRun JSON output path"
      echo "  --state <path>         State file path"
      echo "  --force                Continue with changed packet"
      echo "  --cleanup              Delete state file after success"
      echo "  --verbose              Verbose output"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      PACKET="$1"; shift
      ;;
  esac
done

# --- Validate args ---
if [[ -z "$PACKET" ]]; then
  echo "[ERROR] Missing required argument: <issue-packet.json>" >&2
  exit 2
fi

if [[ "$MODE" != "dryRun" && "$MODE" != "apply" ]]; then
  echo "[ERROR] Invalid mode: $MODE (expected dryRun|apply)" >&2
  exit 2
fi

# --- Auto-detect repo if not specified ---
if [[ -z "$REPO" && "$MODE" == "apply" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
  if [[ -z "$REPO" ]]; then
    echo "[ERROR] Could not detect repository. Use --repo owner/repo" >&2
    exit 2
  fi
  echo "[INFO] Auto-detected repo: $REPO" >&2
fi

# --- Pre-flight checks ---
# Check jq
if ! command -v jq &>/dev/null; then
  echo "[ERROR] jq is required but not found" >&2
  exit 2
fi

# Check gh
if ! command -v gh &>/dev/null; then
  echo "[ERROR] gh CLI is required but not found" >&2
  exit 2
fi

# Check gh auth (only for apply)
if [[ "$MODE" == "apply" ]]; then
  if ! gh auth status &>/dev/null; then
    echo "[ERROR] gh CLI is not authenticated. Run: gh auth login" >&2
    exit 2
  fi
fi

# Check python3 (needed for DAG operations)
if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 is required but not found" >&2
  exit 2
fi

# --- Step 1: Validate input ---
echo "[INFO] Validating input: $PACKET" >&2
if ! "$SCRIPT_DIR/validate.sh" "$PACKET" >&2; then
  echo "[ERROR] Input validation failed" >&2
  exit 2
fi

# --- Step 2: DAG cycle check ---
echo "[INFO] Checking dependency DAG for cycles..." >&2
source "$SCRIPT_DIR/lib/dag.sh"
if ! dag_validate "$PACKET"; then
  echo "[ERROR] Circular dependency detected in DAG" >&2
  exit 2
fi
echo "[INFO] DAG validation passed ✅" >&2

# --- Step 3: Execute mode ---
case "$MODE" in
  dryRun)
    "$SCRIPT_DIR/dry-run.sh" "$PACKET" "$OUTPUT"
    ;;
  apply)
    "$SCRIPT_DIR/apply.sh" "$PACKET" "$REPO" "$STATE_PATH"
    RC=$?

    if [[ "$CLEANUP" == "true" && $RC -eq 0 ]]; then
      rm -f "$STATE_PATH"
      echo "[INFO] State file cleaned up" >&2
    fi

    exit $RC
    ;;
esac
