# Task M6-07: Jujutsu（jj）を任意レイヤーとして導入

- **Status**: `review`
- **Branch**: `arena/docs-runtime-simplification`
- **PR Head**: `feature/gitflow-adoption`
- **Scope**: `docs/contributing/jujutsu.md`, `docs/contributing/jujutsu.en.md`, `docs/INDEX.md`, `docs/INDEX.en.md`, `scripts/status.sh`, `.gitignore`, `AGENTS.md`
- **Upstream Reference**: なし（開発ツール。プロダクトコードには触れない）
- **Next Step**: PR #30 の CI が緑になったら、`jj git init --colocate` 済みの環境で `jj st` / `jj bookmark list` が期待通り動くことを確認し、オーナーのマージを待つ。

---

## 1. 目的と完了条件（Definition of Done）

git を正本のまま、人間が任意で jj（colocated）を使えるようにし、エージェントと CI の手順は
git のまま維持する。

- [x] `jj 0.47.1`（musl）を `~/.local/bin` に導入
- [x] `jj git init --colocate` で `.jj/` を作成（git 履歴は不変）
- [x] jj の作者情報を git の `user.name` / `user.email` に一致させ、`@` に反映
- [x] `.jj/` を `.gitignore` に追加
- [x] 日英ガイド（`docs/contributing/jujutsu.md` / `.en.md`）と INDEX 行を追加
- [x] gitflow ガイドの「関連」からリンク
- [x] `scripts/status.sh` のツールチェーン欄に jj の状態を表示
- [ ] PR #30 の 3 OS CI が緑

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `jj git init --colocate` 済み。ローカル git ブランチがブックマークとして取り込まれ、
    `main@origin` が `trunk()` に設定された。
  - リモートブックマーク（`main` / `develop` / `feature/gitflow-adoption` / `arena/*`）を track。
  - ドキュメント一式と `status.sh` の表示を追加し、`check-docs.py` / `--sync` を通した。
- **作業中・直前の状態**:
  - PR #30（gitflow 完全導入 + CI キャッシュ修正）にこの変更を積み、CI を再実行する。
- **ハマりどころ**:
  - jj は既定でコミットを書き換える。`main` / `develop` など共有ブランチのブックマークは
    書き換えない（ガイドの「注意」に明記）。

---

## 3. 設計判断・技術メモ

- **colocated を選んだ理由**: `scripts/status.sh` / `scripts/gitflow.sh` / CI / `gh` がすべて
  git の ref を見るため、git を正本にしたまま `.jj/` を重ねるのが最も衝突が少ない。
- **エージェントは jj を使わない**: `AGENTS.md` の手順は git のまま。jj は人間のローカル作業用。
- **`status.sh` の `set -e` 修正**: 既存の `[[ ... ]] && VAR=...` は条件不成立時にスクリプトを
  途中終了させ得たため、`if` 文に直した（jj の追加行と同じ形に揃えた）。

---

## 4. 検証ログ

- `jj --version` → `jj 0.47.1-d16ee1fc88a72c54142241b079a34bbf3b033bc0`
- `jj bookmark list` → `main` / `develop` / `feature/gitflow-adoption` / `arena/*` を確認
- `bash scripts/status.sh` → `jujutsu: READY (0.47.1…), colocated`
- `python3 scripts/check-docs.py` → `Documentation check OK (182 markdown files verified)`
