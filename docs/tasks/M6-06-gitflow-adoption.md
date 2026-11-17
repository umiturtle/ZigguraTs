# Task M6-06: gitflow 完全導入（main / develop / feature / release / hotfix）

- **Status**: `review`
- **Branch**: `arena/docs-runtime-simplification`
- **PR Head**: `feature/gitflow-adoption`
- **Scope**: `scripts/gitflow.sh`, `scripts/check-docs.py`, `scripts/status.sh`, `.github/workflows/ci.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `docs/contributing/gitflow*.md`, `docs/INDEX*.md`, `AGENTS.md`
- **Upstream Reference**: なし（ブランチ運用。上流 Tauri のコードには触れない）
- **Next Step**: PR #30（`feature/gitflow-adoption` → `develop`）の再実行 CI を `gh pr checks 30` で確認する。緑ならオーナーが develop へマージする。

---

## 1. 目的と完了条件（Definition of Done）

`develop` ブランチと gitflow のドキュメントだけが存在し、実運用（PR の base・CI・エージェントの
ブランチ）が追いついていない状態を解消する。

- [x] `scripts/gitflow.sh` を復元し、`--check` / `--check-pr-base` / `--self-test` / `--init` を実装
- [x] CI に `gitflow-pr-base` ジョブと `--self-test` を追加し、`develop` / `feature/**` / `release/**` / `hotfix/**` を push トリガに戻す
- [x] `docs/contributing/gitflow.md` / `.en.md` を復元し、現行のブランチモデル（エージェントは `feature/<slug>` を切る）に更新
- [x] `docs/INDEX.md` / `docs/INDEX.en.md` にガイドへの行を追加
- [x] `AGENTS.md` にエージェントの PR 手順（`feature/<slug>` → `develop`）を追記
- [x] `scripts/check-docs.py` の規約 19 で intake（CI トリガ・検証スクリプト・日英ガイド・PR テンプレート）を機械検査
- [x] `scripts/doc-sync.json` を `--sync` で更新
- [x] `./zigw quick-test` / `python3 scripts/check-docs.py` / `bash scripts/gitflow.sh --self-test` のローカルパス
- [ ] PR #30（`feature/gitflow-adoption` → `develop`）で 3 OS CI が緑

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `scripts/gitflow.sh` を再作成（`arena/*` は「`feature/<slug>` を切って `develop` へ」と案内）
  - CI の push トリガ復元、`--self-test` 実行、`gitflow-pr-base` ジョブ追加
  - `docs/contributing/gitflow.md` / `.en.md` 復元＋リリース手順を release ブランチ経由に修正
  - 規約 19 を `scripts/check-docs.py` に追加
  - `AGENTS.md`・PR テンプレート・`status.sh`（PR base 表示）を更新
- **作業中・直前の状態**:
  - 同期台帳を `--sync` で更新済み。PR #30 を作成し、`develop` をマージしてコンフリクトを解消済み（gitflow ガイドは feature 側を採用）。CI 再実行中。
- **ハマりどころ**:
  - 協開発ブランチ `develop` は `ed9fa16`（gitflow ブートストラップ）で、当ブランチとは
    docs の差分がある。PR の base を `develop` にすると、この差分もレビュー対象になる。

---

## 3. 設計判断・技術メモ

- **エージェントのブランチ**: harness が作る `arena/<session>` は作業ログとして残し、PR 用に
  `feature/<slug>` を 1 本だけ切る。`arena/*` を PR head にしないことで、レビュー単位が
  gitflow の命名に揃う。
- **PR base の強制**: `main` ← `release/*|hotfix/*` のみ。`develop` ← `feature/*|arena/*|release/*|hotfix/*`。
  それ以外の非 trunk ブランチ同士は積み上げを許可。
- **`git flow` 本体**: この環境では未インストール。`gitflow.*` の設定キーだけ `--init` で
  書けるようにし、命名の正本は `scripts/gitflow.sh` に置く。
- **規約 19**: 既存の 1〜18 の続き番号として追加。develop 側の「規約 21」は、
  このブランチで 19〜20 が削られているため使わない。

---

## 4. 検証ログ

- `bash scripts/gitflow.sh --self-test` → `OK gitflow names=8 rejected=6 bases=8 base-rejected=6`
- `bash scripts/gitflow.sh --check-pr-base arena/m6-04-feature arena/docs-runtime-simplification` → OK（積み上げ）
- `bash scripts/gitflow.sh --check-pr-base main arena/docs-runtime-simplification` → INVALID（exit 1）
- `python3 scripts/check-docs.py` → `Documentation check OK (180 markdown files verified, 34 reader pages in each of 2 languages)`
- `./zigw quick-test` → `All 10 tests passed.`
- PR #30 の `gitflow PR base` ジョブ → pass (8s)
- **Windows CLI smoke のフレークを修正**: `mlugg/setup-zig@v2` は既定で `.zig-cache`（local/global 両方）をジョブ間でキャッシュする。CLI smoke ジョブが古い manifest を復元し、生成物（`options.zig`, `ubsan_rt.lib`）だけ欠けた状態で `FileNotFound` になっていた（PR イベント run `43703458399` / `43775508184` / `43776587182`）。このジョブは「キャッシュなしのユーザーがビルドできるか」の検証なので `use-cache: false` にした。
