# Task M6-08: 静的チェックを Linux ネイティブ行列から分離（`ci-static`）

- **Status**: `review`
- **Branch**: `arena/docs-runtime-simplification`
- **PR Head**: `feature/separate-static-ci`
- **Scope**: `.github/workflows/ci.yml`, `docs/environment/github-actions.md`
- **Upstream Reference**: なし（CI 構成）
- **Next Step**: `feature/separate-static-ci` → `develop` の PR を作り、`ci-static` が Linux / parity を巻き込まずに単独で走ることを確認する。

---

## 1. 目的と完了条件（Definition of Done）

docs の同期漏れ（`check-docs.py --sync` 忘れ）が Linux ネイティブ行列を落とし、その副作用で
`ci-parity` まで連鎖失敗する構造を解消する。

- [x] `ci-static` ジョブを追加（docs lint・gitflow 名・format・doctest・font・tsc）
- [x] `ci-linux` から静的チェックを外し、Xvfb の `zig build test` 2 本だけにする
- [x] `ci-static` のログを `$GITHUB_STEP_SUMMARY` へミラー（`ci-logs.sh` で読めるように）
- [x] `docs/environment/github-actions.md` に分離の理由を追記
- [ ] PR の CI で `ci-static` が単独で pass する

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `ci-static`（ubuntu-24.04、timeout 20 分）を追加。`check-docs.py` / `gitflow.sh --self-test` /
    `publish-check-run-summary` の Node テスト / `doctest` / `check-font-coverage.mjs` /
    `tsc --noEmit` / `fmt --check` を移動した。
  - `ci-linux` は `xvfb-run ./zigw build test -Dgtk=true` の debug / ReleaseFast のみ。
  - 規約 18 のカウント（`publish-check-run-summary.js` = 5、`continue-on-error: true` = 5）は不変。
- **作業中・直前の状態**:
  - PR を作成して CI を回す段階。
- **ハマりどころ**:
  - `ci-static` に Check Run パブリッシャーを足すと規約 18 の count が崩れるため、
    Step Summary へのミラーのみ行う。

---

## 3. 設計判断・技術メモ

- **なぜ分離するか**: 2026-11-15 の `develop`（`ed9fa16`）で、docs の hash 同期漏れが
  `ci-linux` を即落とし、スクリーンショット artifact が無いことで `ci-parity` も失敗した。
  静的チェックは数秒で終わるので、ネイティブ行列と並列の独立ジョブにすると切り分けが速い。
- **なぜ 3 OS で繰り返さないか**: `check-docs.py` はテキスト検査で OS 非依存。Linux 1 本で十分。
- **失敗の見え方**: `ci-static` が赤なら docs/gitflow/format の問題。`ci-linux` が赤なら
  ネイティブ（GTK/WebKit2GTK）の問題、と切り分けられる。

---

## 4. 検証ログ

- `ruby -e "YAML.load_file('.github/workflows/ci.yml')"` → ok（jobs: ci-static, ci-linux, ci-macos, ci-windows, ci-cli, ci-parity, gitflow-pr-base）
- `python3 scripts/check-docs.py` → OK（規約 18/19 の count も不変）
