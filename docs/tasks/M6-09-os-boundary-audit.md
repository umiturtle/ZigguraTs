# Task M6-09: OS 境界の監査と再発防止テスト体系

- **Status**: `in_progress`
- **Branch**: `feature/os-boundary-audit`
- **Scope**: `scripts/check-os-boundary.py`, `tests/native/`, `src/runtime_native/`, `src/app_runtime.zig`, `build.zig`, `zigw`, `.github/workflows/ci.yml`, `src/tauri/native*.zig`, `src/tauri/{dialog,clipboard,menu,tray}/native*.zig`, `src/webview/{linux,windows,gtk_bindings}.zig`, `src/tauri/native_macos_shim.m`, `docs/architecture/os-boundary-audit.md`
- **Upstream Reference**: `vendor/tauri`, `vendor/wry`, `vendor/tao`（ネイティブ API の意味論の確認）
- **Next Step**: `tests/native/integration.zig` の test 2 を CI の Xvfb で実行し、`native.menuBarFor("main") != null` を確認する。ローカルの sysroot は WebKitNetworkProcess を spawn できないため `ZTS_SKIP_NATIVE_WEBKIT=1` で skip する。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 全問題を [`docs/architecture/os-boundary-audit.md`](../architecture/os-boundary-audit.md) に列挙
- [x] S0: `zts_tauri_native` の相対 import を `@import("zts_tauri")` に置換（Zig の二重所有解消）
- [x] S0: `native_options` / `webview_options` を 1 つの `backend_opts_mod` に統合（P10 の実害を解消）
- [x] L1: 公開モジュールのファイル二重所有を検出する静的検査（自己テスト付き）
- [x] L1: `zts_tauri_native` の相対 import を戻すと赤くなることを確認
- [x] L2: `z_ts` + `zts_tauri` + `zts_webview` + `zts_tauri_native` + `zts_runtime_native` の結合テストを追加
- [x] L2: `WindowObserver` seam と `zts_runtime_native.NativeRuntime` を実装
- [x] L3: GTK 複数選択 double free の回帰テスト（GSList 所有権）
- [x] L3: GTK / macOS トレイの失敗ロールバック回帰テスト（UAF）+ 実装修正
- [x] L3: Win32 `write_html` → `read_html` の短いペイロード往復テスト（OOB）+ 実装修正
- [x] L3: GTK `startDrag` の root 座標修正、GTK の GtkBox レイアウト修正
- [x] L3: macOS shim の main-thread / activation policy 修正
- [x] L4: `WindowExtrasSnapshot` の no-op 検出 + ベースライン
- [x] L4: 未接続公開関数（`setDarkMode` 等）の検出 + ベースライン
- [x] L4: native-wiring / umbrella-purity の検査
- [x] `python3 scripts/check-os-boundary.py` / `--self-test` がローカルでパス
- [x] `python3 scripts/check-docs.py` / `./zigw fmt --check` がパス
- [x] `./zigw quick-test` / `zig build test -Dgtk=false` / `-Dgtk=true` がローカルでパス
- [ ] GitHub Actions `ci-static` / `ci-linux` / `ci-macos` / `ci-windows` で新テストが実行される
- [x] `zigw quick-test` に native を入れない代わりに `./zigw build test-native-integration` を案内する

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - S0 を再現し、`native.zig` / `native_*.zig` / stubs の相対 import をモジュール import に置換。
  - `zts_runtime_native` を新設。`DesktopRuntime.WindowObserver` で window の open/close を観測し、
    メニュー登録・解除を自動化。`z_ts` は native 非依存のまま。
  - `scripts/check-os-boundary.py`（L1/L4、`--self-test`、`--write-baseline`）と
    `tests/native/baseline.txt` を追加。`ci-static` / `zigw docs-check` / `zigw check-os-boundary` に接続。
  - `tests/native/integration.zig` に 3 本の結合テスト（headless wiring / native menu attach / tray rollback）。
  - GTK multi-select double free、GTK/macOS tray rollback、Win32 CF_HTML OOB、GTK startDrag、
    GTK GtkBox レイアウト、macOS shim の thread/policy、GTK write_secret を修正。
  - GTK / macOS の programmatic close でも `close_handler` を通知し、`WindowRegistry` と
    `NativeRuntime` のメニュー登録が残らないようにした（Win32 と同挙動）。
  - `-Dgtk=false` / `-Dgtk=true` の `zig build test` がローカルで成功（表示なしの skip を含む）。
  - Xvfb + sysroot では WebKitNetworkProcess を spawn できないため、native window を使う test 2 だけは
    ローカルで skip する。CI のシステム WebKit では実行する。
- **検証結果（2026-11-17 / ローカル）**:
  - `./zigw quick-test`: 10/10 pass。
  - `./zigw build test -Dgtk=false --summary all`: 57/57 steps、失敗 0。
  - `./zigw build test -Dgtk=true --summary all`: 59/59 steps、失敗 0（表示なしの 9 件は skip）。
  - `xvfb-run ./zigw build test-native-integration -Dgtk=true`（`ZTS_SKIP_NATIVE_WEBKIT=1`）:
    2 pass / 1 skip。test 3（トレイ rollback）と test 1（headless wiring）は実走。
  - `python3 scripts/check-os-boundary.py`: 60 findings / 60 known（新規 0）。
  - `python3 scripts/check-docs.py`: OK（186 files）。
  - `./zigw fmt --check`: OK。
- **CI 初回（PR #32）で見つかった追加バグ**:
  - GTK: `gtk_container_add` で `GtkBox` に入れると `expand=FALSE` になり、
    スクリーンショットが 900×1 になった。`gtk_box_pack_start(..., TRUE, TRUE, 0)` に修正。
  - macOS: トレイの `trays.append` が `apply` より先に残っており、失敗時に解放済み
    entry を `find()` が読んで segfault。GTK と同じ「成功後に append」へ修正。
- **次にやる 1 手**:
  - 修正を push し、PR #32 の Linux Xvfb / macOS / Cross-OS parity を再実行して確認する。

---

## 3. 設計判断・技術メモ・ハマりどころ

### 3.1 なぜ静的検査から始めるか

Zig の二重所有エラーは「消費者が両モジュールを同じコンパイルに入れたとき」だけ出る。
リポジトリ内の `zig build test` はモジュールごとに別 `addTest` なので、この条件を作らない。
消費者テスト（L2）だけでは、新しい公開モジュールが増えたときに同じ穴が再発するため、
`build.zig` の公開モジュール表そのものを検査する L1 を先に置く。

### 3.2 ベースライン方式

現時点の負債（未配線、no-op、dead code）をいきなり全件失敗にすると CI が赤くなり、
「テスト体系を入れたのに通らない」状態になる。`tests/ci/os-boundary-baseline.txt` に
`<rule>|<path>|<detail>` 形式で既知の負債を記録し、**ベースラインにない新規違反だけ**を
失敗させる。負債を直したら行を消す（増やすときは監査 MD に理由を書く）。

### 3.3 モジュール所有権の判定

- 対象は `b.addModule("name", ...)` の**公開モジュールのみ**。
  `b.createModule` のテスト/実行ファイル root は別コンパイルなので対象外
  （`src/docsite/main.zig` が `src/docsite/mod.zig` を相対 import しても合法）。
- `@import("...")` のうち `.zig` で終わるものだけをファイル辺として辿る。
  モジュール名（`std`, `zts_*`, `native_options`）は辺ではない。
- コメント / 文字列 / 複数行文字列（`\\`）を除去してから正規表現を当てる。
  `src/docsite/apidoc.zig` のサンプルコード内 `@import` を誤検出しないため。
- 同一ファイルが 2 つの公開モジュールから到達可能なら `ERR module-ownership`。

### 3.4 ネイティブ回帰テストの作り方

- GTK の double free は `gtk_file_chooser` を自動操作できないため、
  `GSList` を直接構築して生産コードのヘルパに渡す単体テストにする。
  `g_slist_free_full` の二重解放は glibc / Valgrind が検出する。
- GTK / macOS トレイの UAF は、不正な深さの `menu.Snapshot` を渡して
  `apply` を意図的に失敗させ、`statusIconFor` / `statusItemFor` が `null` を返すことを検証する。
- Win32 clipboard は実行中のクリップボードを使うため、テスト後に元の内容を復元するか、
  `OpenClipboard` できない環境では `SkipZigTest` する。

### 3.5 既知の落とし穴

- `zts_tauri_native` の import を `@import("zts_tauri")` に変える際、
  `menu.Accelerator` / `menu.snapshot_wire` は公開済みだが、
  `accelerator.Mods` など未公開の型がある場合は再公開が必要。
- `native.zig` の `pub const menu/tray/dialog/clipboard` は型の同一性のために
  `@import("zts_tauri")` の再エクスポートへ置き換える（相対 import を残すと P1 が再発）。

---

## 4. 並列修正ブランチ（2026-11-18）

`tests/native/baseline.txt` の 60 件のうち、バックエンド固有の **57 件**を 3 ブランチに分割して
並列修正する。各ブランチは `408394f`（PR #32 + 共有 enum 化）を基点にする。

| ブランチ | 担当ファイル | 対象 |
|---|---|---|
| `feature/os-extras-linux` | `src/webview/linux.zig`, `src/webview/gtk_bindings.zig` | Linux の 19 silent-noop（`icon_hash` を除く） |
| `feature/os-extras-macos` | `src/webview/macos.zig`, `src/webview/macos_shim.m` | macOS の 18 silent-noop（`icon_hash` を除く） |
| `feature/os-extras-windows` | `src/webview/windows.zig`, `src/webview/win32.zig`, `src/webview/webview2_com.zig` | Windows の 18 silent-noop + `setDarkMode` 未接続（`icon_hash` を除く） |

- 共有ファイル（`src/core/*`, `src/webview/types.zig`, `src/webview/mod.zig`,
  `src/tauri/*`, `build.zig`）は各ブランチで触らない。共有 enum は `408394f` で導入済み。
- `icon_hash` の 3 件は、画像バイト/パスを `core.Host` 経由で運ぶ API 追加が必要なため、
  並列ブランチとは分離した follow-up PR で扱う（`WindowExtrasSnapshot` は scalar のまま）。
- 各ブランチは自分のバックエンドの baseline 行だけを削除し、`scripts/check-os-boundary.py` と
  `./zigw build test` / 対象 OS のクロスコンパイルで検証する。
