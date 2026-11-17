# ブランチ運用（gitflow）

> **対象読者**: このリポジトリに変更を出す人・リリースを切る人。

このリポジトリは **gitflow** のブランチモデルに従います。長期ブランチの作成・管理は
オーナー（人間）が行い、並列で動く Arena エージェントはセッションの `arena/<session>` から
`feature/<slug>` を 1 本だけ切って `develop` へ PR を出します。
命名と PR base は [`scripts/gitflow.sh`](../../scripts/gitflow.sh) が検証し、CI が毎回
`--self-test` と `--check-pr-base` を実行します（規約 19）。

## ブランチの役割

| ブランチ | 役割 | マージ先 | タグ |
|---|---|---|---|
| `main` | 公開済み。常にリリース可能な状態 | — | `vX.Y.Z` をここに打つ |
| `develop` | 次期リリースの統合 | `main` | 打たない |
| `feature/<slug>` | 1 つの変更単位 | `develop` へ PR | 打たない |
| `release/<x.y.z>` | バージョン固定・最終調整 | `main`（後で `develop` へ戻す） | `main` に `v<x.y.z>` |
| `hotfix/<x.y.z>` | 公開済みバージョンの緊急修正 | `main`（後で `develop` へ戻す） | `main` に `v<x.y.z>` |
| `arena/<agent>` | Arena エージェントのセッション作業ブランチ | PR の head にはしない（`feature/<slug>` を切って出す） | 打たない |

`<slug>` は小文字英数字と `._-`、`<x.y.z>` は SemVer（`1.0.0-beta.1` のような pre-release も可）。
`beta-1.0` のような文字列は Zig の `build.zig.zon` に書けないので使いません。

現在の配置は `main` = リリース済み（`origin/main`）、`develop` = 次期リリースの統合先です。
`develop` は常に `main` より先を進み、リリース時に `release/*` 経由で `main` へ入ります。

## ツール設定

`git flow` 本体を導入すると `git flow feature start <slug>` などが使えます。ブランチ名の正本は
このリポジトリの [`scripts/gitflow.sh`](../../scripts/gitflow.sh) で、CI は同じ表を実行します
（規約 19）。`git flow` に同じ名前を教えるには、リポジトリのローカル設定を 1 回だけ書きます:

```bash
bash scripts/gitflow.sh --init
```

書き込まれるキーは `gitflow.branch.master=main`、`gitflow.branch.develop=develop`、
`gitflow.prefix.feature=feature/`、`gitflow.prefix.release=release/`、
`gitflow.prefix.hotfix=hotfix/`、`gitflow.prefix.support=support/`、
`gitflow.prefix.versiontag=v` です。`--init` は設定を書くだけで、ブランチは作りません。

## 命名を検証する

```bash
bash scripts/gitflow.sh --check feature/window-state
bash scripts/gitflow.sh --check release/0.1.1
bash scripts/gitflow.sh                 # 現在のブランチと推奨 base を表示
bash scripts/gitflow.sh --self-test     # CI が実行する命名テーブル
```

このスクリプトは**ブランチを作りません**。作るのは常にオーナーです。エージェントは
PR の **base** をオーナーが作った `develop` に合わせることだけできます（`--base develop`）。

## PR の base を検証する

CI の `gitflow-pr-base` ジョブがすべての PR で次を検査します。手元でも同じ判定を再現できます:

```bash
bash scripts/gitflow.sh --check-pr-base develop feature/window-state
```

| PR base | 許可される head |
|---|---|
| `main` | `release/<x.y.z>` / `hotfix/<x.y.z>` のみ |
| `develop` | `feature/<slug>` / `arena/<agent>` / `release/<x.y.z>` / `hotfix/<x.y.z>` / `main`（リリース後の back-merge） |
| `feature/*` `release/*` `hotfix/*` `arena/*` | 同じ系統の積み上げ（`arena/*` を含む） |

`main` へ直接 `feature/*` や `arena/*` を向ける PR は落ちます。次期リリースの変更は
`develop` へ、公開版の修正は `release/*` / `hotfix/*` 経由で `main` へ入れます。

## リリース手順

バージョンの正本は `build.zig.zon` の `.version` 1 箇所です。CLI のバージョン、配布 URL、
アーカイブ名、同期台帳がすべて同じ値であることは `scripts/check-docs.py` が検査します。

1. `develop` から `release/<x.y.z>` を切る（オーナー）。
2. `build.zig.zon` の `.version` を `x.y.z` に確定する。
3. `release/<x.y.z>` → `main` の PR をマージし、3 OS CI が緑であることを確認する。
4. `main` のマージコミットにタグを打つ:

   ```bash
   git tag v<x.y.z> <main のコミット>
   git push origin v<x.y.z>
   ```

5. [`Release`](../../.github/workflows/release.yml) ワークフローが `v*` で発火し、
   ソースアーカイブ → `zig fetch` ハッシュ → 3 OS の `zts` バイナリ → `SHA256SUMS` →
   GitHub Release を公開する。
6. `main` を `develop` へ戻す（back-merge）。`release/<x.y.z>` は不要になったら消す。

`--verify-tag` を使うため、タグは必ず **先に** push します。`workflow_dispatch` は
`github.ref_name` がブランチ名になるのでリリースには使いません。

## CI が反応するブランチ

[`ci.yml`](../../.github/workflows/ci.yml) の `push.branches` は `main` / `develop` /
`feature/**` / `release/**` / `hotfix/**` / `arena/**`。どのブランチに push しても同じ
3 OS マトリクスが走ります。Pages と Release は `main` とタグだけです。

## Arena エージェントとの共存

- 各セッションは harness が作る `arena/<session>` ブランチで作業し、そのブランチは
  セッションの作業ログとして残します。
- PR を出すときは、エージェントがその `arena/<session>` から **`feature/<slug>` を 1 本だけ**
  切って push し、`develop` へ PR を出します。PR の head は `feature/<slug>`、base は
  `develop` です（`bash scripts/gitflow.sh --check-pr-base develop feature/<slug>` で検証できます）。
- これにより、エージェント間で共有される `arena/*` は触らずに、レビューとマージの単位だけを
  gitflow の命名に揃えられます。
- [`AGENTS.md`](../../AGENTS.md) と `docs/roadmap/milestones.md` のチェックボックスは
  全ブランチ共有なので編集しません。進捗は `docs/tasks/<ID>-*.md` の 1 タスク 1 ファイルに
  分けます。

## 関連

- [Jujutsu（jj）で作業する（任意）](jujutsu.md) — git ブランチとブックマークを対応させる
- [リポジトリの地図](repository-map.md)
- [ドキュメント同期台帳](doc-sync.md)
- [GitHub Actions の運用](../environment/github-actions.md)
- アプリ作者向けの依存の張り方 → [`../learn/ja/guides/package.md`](../learn/ja/guides/package.md)
