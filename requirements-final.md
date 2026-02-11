# issue-registrar 要件定義書

> version: 1.0 | runId: 20260211-223818 | quality_gate: release
> degraded: gemini=true(429), opus_spawn=true(auth) → inline generation

## 1. 背景と目的

### 背景
claire-OS の開発ライフサイクルにおいて、設計スキル（design-skill）は `issue-packet.json` を出力するが、これを GitHub Issues に登録する手段がない。現在は手動で Issue を作成しており、設計→実装の接続がボトルネックとなっている。

### 目的
`issue-packet.json` を入力として、GitHub Issues を自動登録するスキル（issue-registrar）を提供し、設計→実装のフローを完全自動化する。

## 2. 対象ユーザー / ペルソナ

| ペルソナ | 説明 | 主な操作 |
|---------|------|---------|
| Sho（意思決定者） | 非技術者。dryRun 結果を見て「登録OK」を判断 | dryRun 結果の確認・承認 |
| AI エージェント | Claire/Caty/Alec。スキルを実行して設計→実装フローを回す | スキル実行（dryRun → apply） |
| 実装スキル | system-dev-skill-lite 等。登録された Issue を入力として実装 | 登録済み Issue の参照 |

## 3. スコープ

### In Scope
- issue-packet.json の読み込みとバリデーション（schema v1.0 / v1.1）
- dryRun モード（登録予定一覧の表示：Issue, ラベル, マイルストーン）
- apply モード（GitHub Issues の実際の登録）
- 冪等性（二重登録防止：body メタデータ + ラベル）
- 部分失敗からのリカバリ（run-state.json による再開）
- Epic → Milestone マッピング
- ラベル自動作成（module, priority, epic）
- 依存関係の記録（Issue body に依存先 Issue 番号を記載）
- 実行結果レポート

### Out of Scope
- issue-packet.json の生成（= design-skill の責務）
- Issue の更新/削除/クローズ（v2 以降）
- GitHub Projects への登録（v2 以降）
- Pull Request の自動作成（= 実装スキルの責務）
- Issue の優先順位付け/スケジューリング
- 複数リポジトリへの同時登録
- Slack 通知（呼び出し元スキルの責務）

## 4. 機能要件

### FR-001: issue-packet.json 入力バリデーション
- issue-packet.json を読み込み、schema v1.0/v1.1 に対してバリデーションする
- バリデーションエラー時は、エラー箇所（JSONPath）と理由を一覧表示して停止する
- 検出項目: 必須フィールド欠落、型不一致、ID 形式不正（`EPIC-xxx`, `ISSUE-xxx`）、version フィールドの存在
- schema v1.0 の場合: `body_md`, `milestones` フィールドは任意として扱う
- **Priority: must**

### FR-002: 依存関係 DAG バリデーション
- dependencyDAG の循環依存を検出し、循環パスを含むエラーメッセージを表示して停止する
- DAG 内の参照先が epics/issues に存在しない場合、警告を出す（処理は続行）
- **Priority: must**

### FR-003: dryRun モード
- `mode: dryRun` で実行した場合、以下を出力する:
  - **人間用**: Epic → Issue の階層リスト（タイトル、モジュール、優先度、ラベル、マイルストーン、依存関係）
  - **機械用**: JSON（作成予定の Issue/ラベル/マイルストーン一覧 + 作成順序）
- 作成予定のラベル一覧（新規作成が必要なもの）を明示する
- 作成予定のマイルストーン一覧を明示する
- GitHub API は **一切呼ばない**（バリデーションのみ）
- **Priority: must**

### FR-004: apply モード — Issue 作成
- `mode: apply` で実行した場合、GitHub Issues を実際に作成する
- 基本は `gh issue create` を使用、依存解決等で必要な場合は `gh api` で REST API を直接呼ぶ
- 作成順序: dependencyDAG のトポロジカルソート順（依存先を先に作成）
- 各 Issue 作成後、GitHub Issue 番号を `run-state.json` に記録する
- **Priority: must**

### FR-005: Issue Body 生成
- issue-packet の各 issue から GitHub Issue body を生成する:
  - `body_md` がある場合はそれを使用
  - ない場合は `goal` + `acceptanceCriteria` + `interfaces` + `constraints` + `testPlan` からテンプレートで生成
- body 末尾に冪等性用メタデータブロックを埋め込む:
  ```
  <!-- issue-registrar:v1 {"packetId":"ISSUE-001","epicId":"EPIC-001","version":"1.1"} -->
  ```
- **Priority: must**

### FR-006: 冪等性（Idempotency）
- apply 実行前に、対象リポジトリの既存 Issue を検索し、以下の優先順で重複を判定する:
  1. **一次キー**: ラベル `oc:issue-id=<ISSUE-ID>` の存在
  2. **Fallback**: Issue body 内のメタデータコメント（FR-005）
- 検索対象: リポジトリ全体（**closed Issue を含む**）
- いずれかで既存 Issue が見つかった場合はスキップし、ログに記録する
- **Priority: must**

### FR-007: ラベル自動管理
- 使用するラベル:
  - `module:<module名>` — モジュール識別
  - `priority:<high|medium|low>` — 優先度
  - `epic:<EPIC-ID>` — Epic 所属
  - `oc:issue-id=<ISSUE-ID>` — 冪等性チェック用（一次キー）
- 対象リポジトリに存在しないラベルは自動作成する（色はカテゴリごとにデフォルト値）
- **Priority: must**（冪等性に必要なため should → must に昇格）

### FR-008: マイルストーン管理
- issue-packet の `milestones` を GitHub Milestone に対応させる
- 存在しないマイルストーンは自動作成する
- Epic に対応する Milestone を作成し、配下の Issue に設定する
- milestones フィールドがない場合（v1.0）: Epic 名をそのまま Milestone 名に使用する
- **Priority: should**

### FR-009: 部分失敗リカバリ
- apply 実行中に失敗した場合、進捗状態を `run-state.json` に保存する:
  ```json
  {
    "version": "1.0",
    "packetFile": "issue-packet.json",
    "repo": "owner/repo",
    "startedAt": "ISO-8601",
    "updatedAt": "ISO-8601",
    "created": [{"packetId": "ISSUE-001", "githubNumber": 42, "url": "..."}],
    "failed": [{"packetId": "ISSUE-003", "error": "422 Validation Failed", "retryable": true}],
    "pending": ["ISSUE-004", "ISSUE-005"],
    "labels": {"created": ["module:auth"], "existed": ["priority:high"]},
    "milestones": {"created": ["v1.0-MVP"], "existed": []}
  }
  ```
- 再実行時に `run-state.json` を読み込み、`pending` + `failed`(retryable) の Issue から再開する
- FR-006 の冪等性チェックと組み合わせて、安全な再実行を保証する
- **Priority: must**

### FR-010: 実行結果レポート
- apply 完了後、結果サマリを出力する:
  - ✅ 作成した Issue 一覧（番号 + タイトル + URL）
  - ⏭️ スキップした Issue 一覧（既存のため）
  - ❌ 失敗した Issue 一覧（理由付き）
  - 🏷️ 作成したラベル / マイルストーン一覧
  - 📊 サマリ（作成数 / スキップ数 / 失敗数 / 合計）
- **Priority: must**

### FR-011: リポジトリ指定
- 対象リポジトリを引数で指定する（`owner/repo` 形式）
- 指定がない場合、カレントディレクトリの git remote (`origin`) から推定する
- 事前チェック: `gh repo view owner/repo` でアクセス権を確認し、失敗時はエラーで停止
- **Priority: must**

### FR-012: 依存関係の Issue 間リンク
- Issue body に依存先の GitHub Issue 番号を `Depends on: #123` 形式で記載する
- 依存先が同バッチで作成される場合: 作成後に番号を解決して記載する（トポロジカルソートにより依存先が先に作成されるため可能）
- **Priority: should**

### FR-013: Issue 上限ガード
- 1回の実行で作成する Issue 数の上限を設定可能にする（デフォルト: 50）
- 上限を超える場合、警告を表示して確認を求める（dryRun では常に全件表示）
- **Priority: should**

## 5. 非機能要件

### NFR-001: 実行速度（Performance）
- 30 Issue 以下の packet を 5 分以内に処理完了する（apply モード、ネットワーク正常時）
- GitHub API rate limit（5000 req/h）に対し、1 Issue あたり最大 3 API コール（create + label + milestone）で設計する
- rate limit に到達した場合は `X-RateLimit-Reset` ヘッダを参照して自動待機する
- **Priority: should**

### NFR-002: エラーハンドリング（Reliability）
- GitHub API エラーを分類してハンドリングする:
  - 401/403: 認証/権限エラー → 即停止、run-state 保存
  - 404: リポジトリ not found → 即停止
  - 422: Validation error → 該当 Issue をスキップ、failed に記録
  - 429: rate limit → 自動待機 + リトライ
  - 500/502/503: サーバーエラー → 最大 3 回リトライ（exponential backoff）
- **Priority: must**

### NFR-003: ログ（Observability）
- 各操作をタイムスタンプ付きでログに記録する
- ログは run ディレクトリに `run.log` として保存する
- ログレベル: INFO（作成成功）、WARN（スキップ/既存）、ERROR（失敗）
- **Priority: must**

### NFR-004: セキュリティ
- GitHub トークンをログや出力に含めない
- issue-packet.json の内容はサニタイズせずそのまま Issue body として使用する（GitHub Issue body は Markdown レンダリングで安全）
- **Priority: must**

### NFR-005: 互換性
- issue-packet schema **v1.1 を正として実装**する（v1.0 互換は対象外）
- `gh` CLI v2.x 系を前提とする（`gh --version` で事前チェック）
- **Priority: should**

## 6. 受け入れ条件

### AC-001: dryRun で一覧表示
- **Given** 有効な issue-packet.json がある
- **When** dryRun モードで実行する
- **Then** Epic/Issue の階層リスト + ラベル/マイルストーン作成予定 + JSON が出力され、GitHub API は呼ばれない

### AC-002: apply で Issue 作成
- **Given** 有効な issue-packet.json と対象リポジトリがある
- **When** apply モードで実行する
- **Then** 全 Issue が依存順に GitHub に作成され、番号 + URL の一覧が出力される

### AC-003: 冪等性（二重実行）
- **Given** 同じ issue-packet.json で apply を2回実行する
- **When** 2回目を実行する
- **Then** 既に作成済みの Issue はスキップされ、重複が発生しない

### AC-004: 部分失敗リカバリ
- **Given** apply 実行中に3件目で失敗する
- **When** 再実行する
- **Then** 1-2件目はスキップされ、3件目から再開される

### AC-005: バリデーションエラー
- **Given** schema に違反する issue-packet.json がある
- **When** 実行する
- **Then** エラー箇所（JSONPath）と理由が表示され、GitHub API は呼ばれない

### AC-006: 循環依存検出
- **Given** dependencyDAG に循環がある issue-packet.json がある
- **When** 実行する
- **Then** 循環パスを含むエラーメッセージが表示され、処理が停止する

### AC-007: ラベル自動作成
- **Given** リポジトリに存在しないラベルが必要な issue-packet.json がある
- **When** apply モードで実行する
- **Then** 必要なラベルが自動作成され、Issue に付与される

### AC-008: 依存関係リンク
- **Given** Issue 間に依存関係がある issue-packet.json がある
- **When** apply モードで実行する
- **Then** 依存先の GitHub Issue 番号が body に `Depends on: #N` で記載される

### AC-009: リポジトリアクセス不可
- **Given** アクセス権のないリポジトリを指定する
- **When** 実行する
- **Then** 事前チェックでエラーが表示され、Issue 作成は行われない

### AC-010: rate limit 対応
- **Given** GitHub API rate limit に到達する
- **When** Issue 作成中に 429 を受ける
- **Then** 自動で待機してリトライし、最終的に全 Issue が作成される

### AC-011: dryRun 出力の可読性
- **Given** 有効な issue-packet.json がある
- **When** dryRun を実行する
- **Then** 非技術者（Sho）が読んで「何が作られるか」を理解できる階層リスト形式で出力される

## 7. リスク

| ID | リスク | 影響 | 対策 |
|----|-------|------|------|
| R-001 | GitHub API rate limit 到達 | medium | リトライ + 自動待機、バッチサイズ制限（FR-013） |
| R-002 | gh CLI バージョン差異 | low | `gh --version` 事前チェック、`gh api` フォールバック |
| R-003 | issue-packet schema 変更 | medium | version フィールドで分岐、v1.0/v1.1 両対応 |
| R-004 | 冪等性メタデータの破壊 | high | body コメント + ラベルの2重チェック（FR-006） |
| R-005 | 大量 Issue（100+）のタイムアウト | low | FR-013 の上限ガード + NFR-001 の待機ロジック |

## 8. 依存関係

- GitHub CLI (`gh`) v2.x がインストール・認証済み
- design-skill の issue-packet-schema.json（v1.0 / v1.1）
- 対象リポジトリへの write 権限（Issues + Labels + Milestones）
- claire-OS スキル基盤（SKILL.md 形式）

## 9. 前提

- 1回の実行で1つのリポジトリのみ対象とする
- issue-packet.json は design-skill が生成したものを入力とする（バリデーションは行う）
- gh CLI の認証は事前に完了している
- Epic は GitHub Milestone にマッピングする（GitHub に native Epic 機能がないため）
- Issue の作成順序は dependencyDAG のトポロジカルソートに従う

## 10. 未決事項

### Open Questions

| ID | 質問 | 理由 | Blocking |
|----|------|------|----------|
| Q-001 | schema v1.1 の v1.0 からの差分は？ | design-skill 側で未確定の可能性 | No（v1.0 ベースで開発可） |
| Q-002 | ラベル命名の prefix 規則を統一するか？ | 他スキルとの一貫性 | No |
| Q-003 | Epic→Milestone マッピングで良いか？ | GitHub Projects の方が適切な場合あり | No |

### Decisions Pending

| ID | 決定事項 | 選択肢 | 推奨 | Owner |
|----|---------|--------|------|-------|
| D-001 | メタデータ埋め込み方式 | (a) body コメントのみ (b) ラベルのみ (c) 両方 | (c) 両方 | チーム |
| D-002 | dryRun 人間用出力フォーマット | (a) Markdown テーブル (b) 階層リスト (c) 両方 | (b) 階層リスト | Sho |

---

## 変更履歴（ChangeLog）

| 変更 | Before | After | 理由 |
|------|--------|-------|------|
| FR-007 priority | should | must | 冪等性(FR-006)にラベルが必要なため |
| FR-009 run-state | スキーマ未定義 | JSON スキーマ明記 | Review F-001 指摘 |
| FR-003 出力項目 | ラベル一覧なし | ラベル/MS作成予定を明記 | Review F-002 指摘 |
| FR-013 追加 | なし | Issue上限ガード | Review F-003 (大量Issue対策) |
| FR-004 API方針 | gh CLI のみ | gh CLI + gh api 併用 | Review F-004 指摘 |

---

*Generated by ai-orchestration-requirements skill*
*Run: 20260211-223818 | Iterations: 1 (early termination: High=0) | Degraded: gemini=true, opus_spawn=true*
