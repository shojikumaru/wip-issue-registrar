---
name: issue-registrar
description: >
  issue-packet.json (design-skill output) を GitHub Issues に自動登録するスキル。
  dryRun で確認 → apply で登録。冪等性・部分失敗リカバリ対応。
  Triggers: issue登録, Issue登録, issue-registrar, GitHub Issue作成
---

# issue-registrar

## Overview
design-skill が出力する `issue-packet.json` を入力として、GitHub Issues を自動登録する。

- **dryRun**: 作成予定一覧を表示（GitHub API 呼ばない）
- **apply**: トポロジカルソート順に Issue を作成
- **冪等性**: ラベル `oc:issue-id=<ID>` + body メタデータの2重チェック
- **部分失敗リカバリ**: `run-state.json` で中断点から再開

## Dependencies
- `gh` CLI v2.x（認証済み）
- `jq`
- `python3`
- `bash`

## Usage

```bash
# dryRun（デフォルト）
scripts/register.sh issue-packet.json

# dryRun + JSON出力
scripts/register.sh issue-packet.json --output plan.json

# apply
scripts/register.sh issue-packet.json --mode apply --repo owner/repo

# 部分失敗から再開
scripts/register.sh issue-packet.json --mode apply --repo owner/repo

# パケット変更時に強制続行
scripts/register.sh issue-packet.json --mode apply --repo owner/repo --force

# 完了後にstate削除
scripts/register.sh issue-packet.json --mode apply --repo owner/repo --cleanup
```

## Options
| Option | Default | Description |
|--------|---------|-------------|
| `--mode` | `dryRun` | `dryRun` or `apply` |
| `--repo` | auto-detect | Target repository (`owner/repo`) |
| `--output` | - | dryRun JSON output path |
| `--state` | `.issue-registrar-state.json` | State file path |
| `--force` | false | Continue with changed packet |
| `--cleanup` | false | Delete state file after success |
| `--verbose` | false | Verbose logging |

## Exit Codes
| Code | Meaning |
|------|---------|
| 0 | Success (all issues created/skipped) |
| 1 | Partial failure (some issues failed) |
| 2 | Fatal error (validation, auth, repo access) |

## Labels Created
- `epic:<EPIC-ID>` — Epic grouping
- `module:<name>` — Module identification
- `priority:<level>` — Priority (high/medium/low)
- `oc:issue-id=<ISSUE-ID>` — Idempotency key

## File Structure
```
skills/issue-registrar/
  SKILL.md
  scripts/
    register.sh          # Entry point
    validate.sh          # Input validation (FR-001)
    dry-run.sh           # dryRun mode (FR-003)
    apply.sh             # apply mode (FR-004/005/012)
    lib/
      dag.sh             # DAG operations (FR-002)
      gh-wrapper.sh      # gh CLI wrapper (NFR-001/002)
      idempotency.sh     # Idempotency checks (FR-006)
      state.sh           # State management (FR-009)
  templates/
    issue-body.md.tmpl   # Issue body template
  schemas/
    issue-packet.v1.1.schema.json
```
