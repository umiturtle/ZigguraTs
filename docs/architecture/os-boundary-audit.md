# OS 境界（ネイティブ層）監査 — 問題点・未実装・パッケージ分割

> **内部資料です。** アプリ作者向けではありません。利用側の契約は
> [`zts-webview-backends.md`](zts-webview-backends.md)、
> [`tauri-dialog-clipboard.md`](tauri-dialog-clipboard.md)、
> [`tauri-menu-tray.md`](tauri-menu-tray.md) を参照してください。
>
> 対象: 2026-11-17 時点の `feature/os-boundary-audit`。
> 監査対象は `src/tauri/native*.zig`、`src/tauri/{dialog,clipboard,menu,tray}/native*.zig`、
> `src/webview/{linux,macos,windows}.zig`、`src/webview/macos_shim.m`、`src/core/host.zig`、
> および `build.zig` のモジュール宣言。

このページは「OS 境界がどこで壊れているか」を **再現可能な形** で列挙し、
再発を防ぐテスト体系（[`docs/tasks/M6-09-os-boundary-audit.md`](../tasks/M6-09-os-boundary-audit.md)）
の根拠にするためのものです。数値や対応率ではなく、**観測した事実と再現手順**だけを書きます。

---

## 0. 結論

1. **最優先（S0）: `zts_tauri_native` は `zts_tauri` と同じコンパイル単位に置けない。**
   Zig が `file exists in modules` で拒否するため、ドキュメントに書かれた
   `native.menuBackend()` / `native.dialogBackend()` の配線がコンパイルできない。
2. **S1: ネイティブ層にメモリ安全性のバグが複数ある。**
   GTK 複数選択の double free、GTK/macOS トレイのエラー経路 UAF、
   Win32 `read_html` の 1 MiB 固定長読み取り（領域外アクセス）。
3. **S1: macOS ダイアログが AppKit のスレッド規約とアクティベーションポリシーを破る。**
4. **S2: OS 側に到達しない setter / event が多い。**
   theme、cursor、progress、badge、effects、shadow、icon、monitor provider、
   メニューアイコン、トレイの position / rect など。
5. **パッケージ分割: 「排他 DAG」の不変条件が実コンパイルで破れている。**
   `src/tauri/` と `src/core/` に複数モジュールが同居し、ドキュメントの所有表ともずれている。
6. **テストの穴: CI は各モジュールを別ターゲットでビルドするため、上記の同居エラーを検出できない。**
   `zigw quick-test` はネイティブ層を一切実行しない。

---

## 1. 再現手順（S0）

```bash
# 1) 両モジュールを同時に import する最小の root を用意する
cat >/tmp/consumer.zig <<'EOF'
const tauri = @import("zts_tauri");
const native = @import("zts_tauri_native");
export fn wire(states: *tauri.CorePluginStates) void {
    _ = states.withMenuBackend(native.menuBackend());
}
EOF

# 2) Zig のモジュール指定でコンパイルする（native_options は enable_* = false）
zig test -fno-emit-bin \
  --dep zts_foundation --dep zts_web --dep zts_core --dep zts_rpc \
  --dep zts_tauri --dep zts_tauri_native \
  -Mroot=/tmp/consumer.zig \
  -Mzts_foundation=src/core/foundation.zig \
  --dep zts_foundation -Mzts_web=src/core/web.zig \
  --dep zts_foundation --dep zts_web -Mzts_core=src/core/mod.zig \
  --dep zts_foundation -Mzts_rpc=src/rpc/mod.zig \
  --dep zts_foundation --dep zts_web --dep zts_core --dep zts_rpc -Mzts_tauri=src/tauri/mod.zig \
  --dep zts_foundation --dep zts_web --dep zts_core --dep zts_rpc --dep zts_tauri --dep native_options \
  -Mzts_tauri_native=src/tauri/native.zig \
  -Mnative_options=/tmp/native_options.zig
```

観測結果:

```text
src/tauri/dialog/mod.zig:1:1: error: file exists in modules 'zts_tauri' and 'zts_tauri_native'
src/tauri/dialog/mod.zig:1:1: note: files must belong to only one module
src/tauri/mod.zig:24:28: note: file is imported here by the root of module 'zts_tauri'
src/tauri/native.zig:38:28: note: file is imported here by the root of module 'zts_tauri_native'
```

同様の二重所有は少なくとも次のファイルで起きる（`native.zig` から相対 import される
`zts_tauri` 所有ファイル）:

- `src/tauri/dialog/mod.zig`, `src/tauri/clipboard/mod.zig`
- `src/tauri/menu/mod.zig`, `src/tauri/tray/mod.zig`
- `src/tauri/path.zig`（`dialog/native_gtk.zig` から）
- `src/tauri/menu/accelerator.zig`, `src/tauri/menu/snapshot_wire.zig`
- `src/tauri/channel.zig` / `src/tauri/resources.zig`（`menu/mod.zig` / `tray/mod.zig` 経由）
- `src/tauri/fs/*.zig`（`dialog/mod.zig` 経由）

原因は `src/tauri/native.zig:38-41` と各 `native_*.zig` の `@import("mod.zig")` /
`@import("../path.zig")` が、モジュール名ではなく**ファイルパス**で `zts_tauri` の
ファイルを再取り込みしていること。`build.zig:246` は `zts_tauri` を import として
宣言しているのに、コード側が使っていない。

---

## 2. S1 — メモリ安全性

| # | 場所 | 内容 | 再現 / 検出方法 |
|---|---|---|---|
| M1 | `src/tauri/dialog/native_gtk.zig:109`, `:120` | `gtk_file_chooser_get_filenames()` の各文字列を `fromGtkAlloc()` が `g_free` し、その後 `g_slist_free_full(list, g_free)` が同じ文字列を再度解放。複数ファイル選択で **double free**。 | Xvfb 上で 2 件以上選択する E2E、または GSList を直接渡す単体テスト + Valgrind |
| M2 | `src/tauri/tray/native_gtk.zig:163-166` | `icons.append()` 後に `createIcon()` / `apply()` が失敗すると `errdefer` が `entry` と `owned` を解放するが、`icons` リストに**解放済みポインタが残る**。以後の `find()` で UAF。 | 不正な深さの `menu.Snapshot` を渡して `create()` を失敗させ、`statusIconFor(id)` が `null` を返すことを検証 |
| M3 | `src/tauri/tray/native_macos.zig:168-178` | 同上。さらに `entry.handle`（`NSStatusItem`）が解放されずリーク。 | 同上（`statusItemFor(id)`） |
| M4 | `src/tauri/clipboard/native_windows.zig:113` | `bytes[0 .. 1 << 20]` を無条件に走査。`HTML Format` の実サイズが小さい場合、**確保領域外の読み取り**。 | `write_html` → `read_html` の短いペイロード往復テスト（Windows CI） |
| M5 | `src/tauri/dialog/native_gtk.zig` `addFilters` | `gtk_file_filter_new()` 後の OOM で floating ref がリーク（軽微）。 | 失敗注入アロケータ（将来の改善） |

### 2.1 所有権の誤り（メモリ安全ではないが契約違反）

- `src/tauri/clipboard/native_windows.zig:118`: `write_html` が `alt_text` を**完全に無視**し、
  `CF_UNICODETEXT` フォールバックも設定しない。HTML を解釈できないアプリには何も渡らない。
- `src/tauri/clipboard/native_windows.zig:113`: `read_html` は CF_HTML ヘッダ込みの生文字列を返す。
  GTK / macOS はフラグメントを返すため、**同じ API が OS ごとに違う意味**になる。

---

## 3. S1 — macOS ダイアログのスレッド / ポリシー

| 場所 | 内容 |
|---|---|
| `src/tauri/native_macos_shim.m:56-60` | `zts_prepare_app()` が `[NSApplication sharedApplication]` と `setActivationPolicy:` を呼ぶ。 |
| `src/tauri/native_macos_shim.m:74`, `:150` | `zts_prepare_app()` は `isMainThread` 判定と `dispatch_sync` の**外**で実行される。ワーカースレッドから呼ぶと AppKit をオフメインで触る。 |
| 同上 | `NSApplicationActivationPolicyAccessory` を無条件に設定するため、通常の GUI アプリがダイアログ表示後に Dock / メニューバーを失う可能性がある。 |

正しい形: 既存の `activationPolicy` を保存し、`@autoreleasepool` 内の main-thread ブロックで
必要なときだけ変更し、終了時に復元する（または変更しない）。

---

## 4. S1 — GTK のウィンドウ操作

| 場所 | 内容 |
|---|---|
| `src/webview/linux.zig:1084` | `gtk_window_begin_move_drag(gtk_win, 1, 0, 0, 0)`。root 座標が `(0,0)` のため、`data-tauri-drag-region` のドラッグ開始時にウィンドウがジャンプする。現在のポインタ位置（`gdk_device_get_position`）を渡す必要がある。 |
| `src/tauri/menu/native_gtk.zig:253` + `src/webview/linux.zig:689` | GTK メニューは「ウィンドウ直下の子が `GtkBox`」を要求するが、`zts_webview` は `GtkWindow` に `WebKitWebView` を直接追加する。自前のウィンドウにメニューバーを付けられず、**常に `error.Unsupported`**。 |
| `src/tauri/menu/native_gtk.zig:269-285` | `registerWindow` は `applyTo` が失敗しても `windows` リストに登録を残す。ウィンドウ破棄後にダングリング参照になる。 |
| `src/tauri/menu/native_gtk.zig` `applyTo` | `attach` が古いバーを破棄した後に `Unsupported` を返すと、`entry.menu_bar` が解放済みウィジェットを指したまま残る。 |

---

## 5. S1 — クリップボードの秘密情報

| 場所 | 内容 |
|---|---|
| `src/tauri/clipboard/native_gtk.zig:100-103` | `write_secret` が `writeTextImpl` を呼び、その中で `gtk_clipboard_store()` を実行する。`gtk_clipboard_store` は「アプリ終了後も残す」API であり、**秘密情報をクリップボード履歴に永続化**する。コメントの「履歴に残さない」と真逆。 |

macOS は `org.nspasteboard.ConcealedType`、Windows は
`ExcludeClipboardContentFromMonitorProcessing` を使っており、Linux だけ挙動が逆。

---

## 6. S2 — OS 側に到達しない setter / event（no-op）

これらは「成功したように見えて OS に何も起きない」ため、アプリ作者から見ると最も厄介です。

### 6.1 ウィンドウ / WebView

| 機能 | 現状 | 場所 |
|---|---|---|
| `set_theme` / ダークモード | extras と JS イベントのみ。`theme` を読む backend はない。 | `src/tauri/window.zig:907`、`src/webview/*/applyWindowExtras` |
| `WindowConfig.theme` | 作成時に未適用。 | `types.zig:450-466` |
| `set_progress_bar` | extras 記録のみ。 | `src/tauri/window.zig:926` |
| `set_badge_count` | extras 記録のみ。 | `src/tauri/window.zig:942` |
| `set_cursor_icon` / `position` / `grab` / `visible` | extras 記録のみ。 | `src/tauri/window.zig:951-989` |
| `request_user_attention` | extras 記録のみ。 | `src/tauri/window.zig:1000` 付近 |
| `set_shadow` / `set_effects` / `set_background_color` / `set_icon` | extras 記録のみ。`background_color` は作成時も GTK のみ。 | `src/tauri/window.zig:1035-1082` |
| `dragDropEnabled` / `zoomHotkeysEnabled` / `windowEffects` | 保持・ハッシュ化のみ。 | `src/webview/types.zig:450-466` |
| `setDarkMode` | Windows backend に実装があるが**どこからも呼ばれない**。 | `src/webview/windows.zig:1423` |
| ウィンドウイベント | `tauri://file-drop` / `page-load` / `navigation` / `scale-changed` は許可リストにあるが、どの backend も発火しない。 | `src/tauri/window.zig:722-740` |
| Monitor / DPI | native provider が存在せず、`setProvider()` はテスト以外で未使用。常にダミーの 1920×1080。 | `src/tauri/monitor.zig:77-81` |
| `close_devtools` / `clear_all_browsing_data` | 明示的 no-op（ドキュメント済み）。 | `src/tauri/webview.zig:357,379` |

### 6.2 メニュー

- **アイコン（`IconMenuItem`）が全 OS で未実装**。`menu.Entry`（`src/tauri/menu/mod.zig:504`）に
  `icon` フィールドがなく、`snapshot_wire.WireEntry` にもない。`Icon.fromValue` は受け付けるが
  静かに捨てる（`src/tauri/menu/mod.zig:271`）。
- **Predefined のネイティブ role は macOS のみ**（`src/tauri/menu/native_macos_shim.m:112-130`）。
  GTK / Win32 は通常項目として `MenuId` を送るだけ。
- Win32 のアクセラレータは表示テキストのみ。`TranslateAcceleratorW` 未実装
  （`docs/architecture/tauri-menu-tray.md` §4.4 に既知の制限として記載）。
- アプリメニューの実配線がない。`DesktopRuntime` は `registerMenuWindow` を呼ばず、
  label → native handle の変換ヘルパーもない。

### 6.3 トレイ

- イベントの `position` / `rect` が **全 OS で 0**（`tray/native_windows.zig` の `emit`、
  `tray/native_macos.zig` の `onEvent`、`tray/native_gtk.zig` の `onActivate` / `onPopupMenu`）。
- `Enter` / `Leave` 未発火（Windows は `Move` のみ）。
- `icon.resource` は全 OS で無視。GTK の `image.bytes` はプレースホルダにフォールバック。
- GTK の `menu_on_left_click` が無視される。
- GTK は `GtkStatusIcon` のため **Wayland ではトレイが出ない**。検出・フォールバックなし。

### 6.4 ダイアログ / クリップボード

- `write_image` / `read_image` 未実装（ドキュメント済み）。
- GTK / Win32 で `directory: true, multiple: true` の複数フォルダ選択ができない
  （`dialog/native_gtk.zig:96-98`, `dialog/native_windows.zig:344`）。macOS は対応。
- macOS は複数 filter を 1 つの拡張子リストに union するため、フィルタのドロップダウンがない。
- Win32 の `save` は `defaultPath` を `SetFileName` にそのまま渡す（`SetFolder` + `SetFileName`
  に分けない）。

---

## 7. スレッド契約の破綻

`src/core/host.zig:139-140` は「**Every method is safe to call from any thread**」と明記しているが、
実際にスレッド安全なのは `wakeup()` / `completeRequest()` 程度。

- GTK / AppKit / Win32 のウィンドウ操作は呼び出しスレッドで直接実行される
  （`src/webview/linux.zig:952` 以降、`src/webview/windows.zig:1686` 以降）。
- `src/tauri/native_gtk.zig:240` の `gtk_ready`、`src/tauri/dialog/native_windows.zig:137` の
  `com_ready` はロックなしのグローバルキャッシュ。最初に別スレッドが触ると race。
- macOS のクリップボードシムはダイアログと違い main queue にホップしない。
- macOS ダイアログの `dispatch_sync(dispatch_get_main_queue(), ...)` は、main thread が
  RPC 応答待ちでブロックしているとデッドロックし得る。

→ 「main thread のみ」に契約を絞るか、`WebviewHost` / ネイティブ backend で main-thread キューに
marshal するかのどちらかに統一する必要がある。

---

## 8. パッケージ分割の問題

| # | 問題 | 根拠 |
|---|---|---|
| P1 | `zts_tauri_native` と `zts_tauri` が同一ファイルを二重所有し、同時 import 不可 | §1。`native.zig:38-41` |
| P2 | `build.zig:236-248` の宣言 import（`zts_core` / `zts_rpc` / `zts_web` / `zts_foundation` / `zts_tauri`）が未使用。実依存は相対 import | `native.zig` に `@import("zts_tauri")` がない |
| P3 | 「各 `.zig` は単一モジュールにのみ所属する排他 DAG」という不変条件が実コンパイルで破れている | `docs/architecture/00-overview.md:54` |
| P4 | `zts_tauri_native` は `z_ts` から再公開されず、`DesktopRuntime` も生成テンプレートも使わない | `src/root.zig:24-26`, `src/app_runtime.zig:79-125`, `src/cli/template.zig:242-290` |
| P5 | `plugin:dialog` / `plugin:clipboard-manager` は `CorePluginsSchema` / `CorePluginStates` に含まれず、`DesktopRuntime` から差し込む API もない | `src/tauri/mod.zig:69-80, 92-110` |
| P6 | `zts_tauri_native` のモジュール doc が「dialog & clipboard のみ」と書いているが、実際は menu / tray も含む | `src/tauri/native.zig:1-10` |
| P7 | `zts_tauri` と `zts_tauri_native` が `src/tauri/` を、`zts_foundation` / `zts_web` / `zts_core` が `src/core/` を共有 | `build.zig` の root 一覧 |
| P8 | `zts_webview` が native / mock / C ABI を 1 パッケージに同梱。GTK が見つかると HeadlessMock だけの消費者も `link_libc=true` + GTK/WebKit リンクになる | `build.zig:147-162` |
| P9 | `DesktopRuntime` / `WebviewHost` / `BridgeHost` は umbrella `z_ts` 専属。デスクトップだけ欲しい消費者も `zts_ssg` / `zts_wasm` / `zts_bridge` を含む `z_ts` に依存する | `build.zig:314-329`, `src/root.zig` |
| P10 | `native_options` と `webview_options` が同名フィールドを別々に定義。片方だけ変わると backend 判定がずれる | `build.zig:78-88` |
| P11 | `zts init` の生成物は embedder のみで、`z_ts` のランタイムを使わない。新規プロジェクトに OS 境界が存在しない | `src/cli/template.zig:242-290, 330-345` |
| P12 | `zigw quick-test` は `zts_tauri_native` を実行しない。ネイティブ層は full-test / CI まで検証されない | `zigw:106-145` |
| P13 | `tests/standalone_modules.zig` は foundation/web/rpc/bridge/webview のみ。tauri / tauri_native は対象外 | `build.zig:338-350` |
| P14 | 消費者が両モジュールを import するテストがなく、P1 を検出できない | `build.zig:541` の分離テスト |

---

## 9. 再発防止のテスト体系（この監査の成果物）

「同じ種類の問題を確実に洗い出す」ため、次の 4 層を用意する。
実装は [`docs/tasks/M6-09-os-boundary-audit.md`](../tasks/M6-09-os-boundary-audit.md) に従う。

| 層 | 何を検出するか | 実装 |
|---|---|---|
| **L1: モジュール所有権の静的検査** | 公開モジュール間のファイル二重所有（P1 / P3）、未所有ファイル、未使用の宣言 import | `scripts/check-os-boundary.py --self-test`（`ci-static` / `./zigw check-os-boundary`） |
| **L2: クロスパッケージ結合テスト** | `z_ts` + `zts_tauri` + `zts_webview` + `zts_tauri_native` + `zts_runtime_native` の同時コンパイル、vtable の配線、window observer、メニュー登録、トレイのロールバック | `tests/native/integration.zig`（`zig build test` / `./zigw build test-native-integration`） |
| **L3: ネイティブ回帰テスト** | double free / UAF / 領域外アクセス / エラー経路のロールバック / HTML 往復 | 各 backend 内の単体テスト（GTK は Xvfb、macOS/Windows は CI） |
| **L4: no-op / dead-code 検査** | `WindowExtrasSnapshot` の全フィールドが「適用」か「明示的に未対応」に分類されていること、`setDarkMode` のような未接続公開関数、ブリッジの配線漏れ | `scripts/check-os-boundary.py` + `tests/native/baseline.txt` |

L1 / L4 は既知の負債を `tests/native/baseline.txt` に記録して **新規発生だけを失敗**させる。
負債を解消したらベースラインから行を削除する。L2 / L3 は実際に赤くなるテストとして追加する。

**テストの置き場所（散らかさない）**:

- クロスパッケージの結合だけが `tests/native/integration.zig`。ここ以外に「複数パッケージを
  同時 import する」テストを増やさない。
- backend の内部不変条件（GSList の所有権、HMENU のロールバック、クリップボード往復）は
  **その backend のファイル内**の `test` に置く。既存の `native_*.zig` の慣習どおり。
- 静的な監査とベースラインは `scripts/check-os-boundary.py` と `tests/native/baseline.txt` の
  2 ファイルだけ。新しい lint を増やすときはこのスクリプトにルールを足す。

### 9.3 ランタイム結合の設計（`zts_runtime_native`）

`z_ts` は Pure のまま保ち、ネイティブ backend の配線は
**`src/runtime_native/mod.zig`（`zts_runtime_native`）** が所有する。

```text
z_ts.DesktopRuntime ── WindowObserver ──► zts_runtime_native.NativeRuntime
        │                                      ├─ withMenuBackend / withTrayBackend
        │                                      ├─ dialog_state / clipboard_state
        └─ engine.nativeHandle() ─────────────► native.registerMenuWindow / unregister
```

- `DesktopRuntime` に追加した `WindowObserver` は **native 非依存の汎用 seam**。
  `onOpen` / `onClose` は JS から作られたウィンドウにも効くので、アプリ側の label 管理が不要。
- `zts_runtime_native` は `z_ts` + `zts_tauri` + `zts_tauri_native` に依存する。`z_ts` に
  native への依存は一切足さない（headless / HTTP / WASM の消費者に GTK を押し付けない）。
- `CorePluginStates` に dialog/clipboard は足さない。上流どおり別プラグインなので、
  `PluginSchema` をアプリの schema に merge し、`NativeRuntime` の state を bind する。

### 9.1 なぜ既存 CI で見逃したか

- `zig build test` は `zts_tauri` と `zts_tauri_native` を**別々の `addTest`** でビルドする
  （`build.zig:540-541`）。同一コンパイルにならないので、Zig の二重所有エラーが出ない。
- `./zigw quick-test` はネイティブ backend を `enable_*=false` でビルドし、
  `zts_tauri_native` をそもそも実行しない（`zigw:106-145`）。
- 既存の docs ルール 17 は「トークンが存在するか」を見るだけで、
  「OS に届いているか」「メモリ所有権が正しいか」は見ていない。

### 9.2 追加するテストの受け入れ条件

- L1: `zts_tauri_native` の相対 import を戻すと必ず失敗する（自己テストで確認）。
- L2: `native.*Backend()` を `tauri.*` の型に渡すコードがコンパイルできる。
- L3: GTK 複数選択のヘルパ、トレイの失敗ロールバック、Win32 HTML 往復が CI で実行される。
- L4: `WindowExtrasSnapshot` に新フィールドを足して backend が無視すると失敗する。

---

## 10. 修正状況（M6-09 / `feature/os-boundary-audit`）

### 10.1 解消済み

| 項目 | 対応 |
|---|---|
| §1（S0 / P1）`zts_tauri_native` のファイル二重所有 | `native.zig` / `native_*.zig` / stub を `@import("zts_tauri")` に統一。`tests/native/integration.zig` が 5 パッケージを同一コンパイルに置いて検証 |
| P3「排他 DAG」の不変条件 | `scripts/check-os-boundary.py --self-test` と通常検査で機械検証 |
| P10 `native_options` / `webview_options` の二重生成 | `backend_opts_mod` 1 つを両モジュールが共有。結合時に Zig が `file exists in modules` を出す実害を解消 |
| M1 GTK 複数選択の double free | `consumeFilenames` に所有権を集約し、`g_slist_free_full` のみが解放。`gtk multi-select filenames are freed exactly once` テスト追加 |
| M2 / M3 GTK / macOS トレイのエラー経路 UAF | registry への append を `apply` 成功後へ移動。`destroyEntry` に解放を集約。`tests/native/integration.zig` test 3 で全 OS 検証 |
| M4 Win32 `read_html` の 1 MiB 固定長読み取り | `GlobalSize` で実サイズを取得し、CF_HTML の `StartFragment` / `EndFragment` を検証。短い HTML の往復テスト追加 |
| M4 付随: Win32 `write_html` の alt テキスト欠落 | `CF_UNICODETEXT` フォールバックを設定 |
| macOS shim のオフメイン AppKit / activation policy | `zts_prepare_app` を main-thread ブロック内へ移動し、`Accessory` 強制を廃止 |
| GTK `startDrag` の `(0,0)` | `gdk_device_get_position` で現在のルート座標を取得 |
| GTK のウィンドウ構造（メニュー取り付け不可） | `GtkWindow → GtkBox(vertical) → WebView` に変更 |
| GTK `write_secret` の履歴永続化 | `gtk_clipboard_store` を secret 経路では呼ばない |
| ランタイム結合の不在（P4 / P5 の一部） | `zts_runtime_native` + `DesktopRuntime.WindowObserver` を追加。`z_ts` は native 非依存のまま |
| 空 URL でページを読み込んでしまう問題 | `WindowSpec.initial_url = ""` は「blank window（navigate しない）」として扱う |
| プログラム close 後に `WindowRegistry` / メニュー登録が残る（GTK / macOS） | `closeWindow()` でも `close_handler` を呼び、Win32 と同じ経路に統一。結合テストが `resolveId("main") == null` を検証 |

### 10.2 ベースラインに残した既知の負債（60 件）

2026-11-18 から、バックエンド固有の 57 件を `feature/os-extras-{linux,macos,windows}` の
3 ブランチで並列修正中。`icon_hash` の 3 件だけは、実画像を `WindowExtrasSnapshot`（scalar）では
運べないため、`core.Host` に icon 専用の API を足す follow-up PR に分離した。

`tests/native/baseline.txt` を参照。主なもの:

- `WindowExtrasSnapshot` の no-op: `theme` / `progress_*` / `badge_count` / `cursor_*` /
  `user_attention` / `shadow` / `effect` / `bg_*` / `icon_hash`（backend ごとに差あり）。
- `setDarkMode()` が未接続。
- トレイイベントの `position` / `rect`、`Enter` / `Leave`。
- メニューアイコン、GTK/Win32 の predefined role、Win32 のアクセラレータ実行。
- GTK の Wayland トレイ、モニタプロバイダ、`zts init` テンプレートの `DesktopRuntime` 配線。

### 10.3 意図的にテストできないもの

- **ネイティブのモーダルダイアログ**（GTK file chooser / NSOpenPanel / IFileOpenDialog）は
  自動操作できない。テストは「state 生成」「stub の fail-closed」「option/filter の純関数」
  「GSList の所有権」まで。実際の UI は手動確認に残す。
- **macOS のダイアログ**: `NSAlert` / `NSOpenPanel` の表示は main thread とユーザー操作が
  必要。シムの main-thread 強制とポリシー非変更はコードで保証し、E2E は行わない。
- **Windows のクリップボード**: CI の対話ウィンドウステーションが無い場合は `SkipZigTest`。
