# Jujutsu（jj）で作業する（任意）

> **対象読者**: `git` の代わりに `jj` で差分を扱いたい人。

このリポジトリの正本は `git` です。CI・[`scripts/status.sh`](../../scripts/status.sh)・
[`scripts/gitflow.sh`](../../scripts/gitflow.sh)・GitHub の PR はすべて **git のブランチ**を見ます。
`jj` は **colocated モード**でその上に重ねる任意のレイヤーで、導入しなくても開発できます。
エージェントは [`AGENTS.md`](../../AGENTS.md) の git 手順に従ってください。

## 導入

```bash
# 1. バイナリ（Linux x86_64 の例。他の OS は jj の Releases を参照）
mkdir -p ~/.local/bin
curl -sL https://github.com/jj-vcs/jj/releases/download/v0.47.1/jj-v0.47.1-x86_64-unknown-linux-musl.tar.gz \
  | tar -xz -C ~/.local/bin

# 2. このチェックアウトを colocated 化（.jj/ を作るだけで、git の履歴は変えない）
jj git init --colocate

# 3. 作者情報（git の user.name / user.email と同じにする）
jj config set --user user.name  "…"
jj config set --user user.email "…"
jj metaedit --update-author        # 既存の作業コピーコミットへ反映
```

`.jj/` は `.gitignore` 済みです。`vendor/` のサブモジュールは jj からは無視されます。

## ブックマーク = git ブランチ

jj の **ブックマーク**が git のブランチに対応します。colocated 化すると既存ブランチが
ブックマークとして取り込まれ、`main` / `develop` / `feature/*` / `arena/*` の gitflow 名を
そのまま使えます。

```bash
jj bookmark list        # git branch 相当
# リモート追従を有効にする（初回のみ）
jj bookmark track develop@origin feature/gitflow-adoption@origin
```

## 日常の流れ

```bash
jj st                        # 作業コピーの差分
jj describe -m "feat: ..."   # 現在のコミットにメッセージを付ける
jj new                       # 次の変更用に空コミットを積む
jj log -r '::@'              # 祖先の履歴
```

gitflow に沿って PR を出すときは、ブックマークを git ブランチ名に合わせて push します。

```bash
# arena/<session> から feature/<slug> を切る場合
jj new main                                  # base にするコミットへ移動
jj bookmark set feature/<slug> -r @          # PR の head になるブックマーク
jj git push -b feature/<slug>

gh pr create --base develop --head feature/<slug> --title "..." --body "..."
```

`jj git push` は `git push` と同じ ref を更新するので、CI の `gitflow-pr-base` と
`bash scripts/gitflow.sh --check-pr-base develop feature/<slug>` はそのまま働きます。

## 注意

- **同じ作業コピーで git と jj を混ぜない**。`jj st` で状態を確認し、そのターンは片方だけを使います。
- jj はコミットを自動で書き換えます（amend が既定）。push 済みのブックマークを書き換えた場合は
  `jj git push -b <name>` で更新しますが、共有ブランチ（`main` / `develop`）は書き換えないでください。
- エージェント（`arena/*`）と CI は git 前提です。jj は人間のローカル作業用の追加レイヤーです。
- `jj git init --colocate` 済みの環境で `scripts/status.sh` を実行しても、git 側の状態だけを表示します。

## 関連

- [ブランチ運用（gitflow）](gitflow.md) — PR の base とブランチ名
- [リポジトリの地図](repository-map.md) — どのファイルを触るか
- [トラブルシューティング（リポジトリ開発）](troubleshooting.md)
