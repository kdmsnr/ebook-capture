# ebook-capture

電子書籍ビューアの表示中ウィンドウを連続撮影し、ページ送りキーを送る macOS 向けツールです。

このツールは対象アプリや電子書籍ファイルを改変せず、macOS のウィンドウ操作、スクリーンショット、キーボードイベントだけを使います。利用するコンテンツの著作権、配信条件、対象サービスの利用規約を守ってください。

## 必要なもの

- macOS
- 撮影対象の電子書籍ビューア
- Xcode または Command Line Tools
- macOS 権限:
  - Privacy & Security > Accessibility
  - Privacy & Security > Screen & System Audio Recording

## ビルドと起動

```sh
make app
open "dist/Ebook Capture.app"
```

`make app` は `dist/Ebook Capture.app` を作成します。

ビルド成果物を消す場合:

```sh
make clean
```

## 初回の権限設定

初回起動時、macOS から権限を求められたら許可します。手動で設定する場合は、System Settings > Privacy & Security で `Ebook Capture.app` を追加またはオンにします。

- Accessibility: ページ送りキーを対象アプリへ送るため
- Screen & System Audio Recording: 対象ウィンドウを撮影するため

権限を追加またはオンにした後は、`Ebook Capture.app` を一度終了して開き直してください。Screen Recording の権限は、許可した直後の起動中プロセスには反映されないことがあります。

古いビルドに権限を許可済みで、何度も権限を聞かれる場合は、このアプリの権限だけを一度リセットしてから許可し直します。

```sh
tccutil reset Accessibility com.kdmsnr.ebook-capture
tccutil reset ScreenCapture com.kdmsnr.ebook-capture
```

## GUI の使い方

1. 対象アプリで本を開き、撮影したい最初のページを表示します。
2. 対象ウィンドウをフルスクリーン表示にします。
3. `dist/Ebook Capture.app` を開きます。
4. 必要な項目を設定して `Start Capture` を押します。

主な設定:

- App name: 対象アプリ名
- Check Windows: このツールから見えている対象ウィンドウを確認
- Pages: 最大撮影ページ数
- Capture until book end: ページ送り後に画面が変わらなくなったら停止
- Output Folder: PNG の保存先
- Filename: PNG ファイル名の接頭辞
- Page key: ページ送りに使うキー
- Delay: ページ送り後、次の撮影まで待つ秒数
- Self timer: 最初の撮影前に待つ秒数

`Capture until book end` をオンにした場合は、ページ数に達するか、ページ送り後に画面が変わらなくなるかの早い方で停止します。終端検出に失敗しても止まるように、`Pages` は実際のページ数より少し多めに設定してください。

`Ctrl+Q` でアプリを終了できます。

## 撮影前チェック

OCR 精度と PDF 化したときの見た目を安定させるため、撮影前に次を確認してください。

- Night Shift、True Tone、ブルーライトカット系アプリ、色補正フィルタをオフにする
- 電子書籍ビューア側のセピア、ダークモード、背景色変更をオフにする
- 対象ウィンドウをフルスクリーン表示にする
- 文字サイズ、余白、表示倍率を固定してから撮影を始める

キャプチャ中に別アプリへフォーカスしても、ページ送り前に対象アプリを再アクティブ化します。ただし、安定性を優先する場合はキャプチャ中に Mac を操作しないでください。

## CLI

GUI ではなくコマンドラインからも実行できます。

```sh
dist/Ebook\ Capture.app/Contents/MacOS/ebook-capture --app-name "Reader.app" --count 30 --output-dir ./captures --delay 1.0
```

オプション:

```text
-n, --count <number>          撮影ページ数。既定値: 10
    --until-end               ページ送り後に画面が変わらなくなるまで撮影。--count は上限ページ数
-o, --output-dir <directory>  画像の保存先ディレクトリ。既定値: captures
    --delay <seconds>         ページ送り後の待機秒数。既定値: 0.8
    --self-timer <seconds>    初回撮影前のセルフタイマー秒数。既定値: 0
    --key <key>               right, left, page-down, page-up, space。既定値: page-down
    --app-name <name>         macOS アプリ名
    --bundle-id <id>          アプリの Bundle Identifier
    --window-title <text>     指定文字列を含むウィンドウを優先
    --prefix <text>           PNG ファイル名の接頭辞。既定値: page
    --list-windows            撮影せず、見えている対象ウィンドウを表示
```

## 出力

既定では次のような PNG が作成されます。

```text
page-0001.png
page-0002.png
page-0003.png
```

GUI の既定の保存先は `~/Pictures/Ebook Capture` です。CLI の既定の保存先は実行ディレクトリ配下の `captures` です。

## 他の Mac で使う場合

バイナリを配布せず、各自の Mac でソースからビルドして使う場合は次の手順です。

```sh
git clone https://github.com/kdmsnr/ebook-capture.git
cd ebook-capture
make app
open "dist/Ebook Capture.app"
```

各ユーザーの Mac で初回だけ Accessibility と Screen & System Audio Recording の許可が必要です。

他人に完成済みの `.app` や `.dmg` を配布する場合は、通常は Apple Developer ID 署名と notarization が必要になります。このリポジトリの `make app` は開発・自分用のビルドを想定しています。

## トラブルシュート

### 権限を許可してもキャプチャできない

`Ebook Capture.app` を終了して開き直してください。まだ直らない場合は、古い権限をリセットしてから再度許可します。

```sh
tccutil reset Accessibility com.kdmsnr.ebook-capture
tccutil reset ScreenCapture com.kdmsnr.ebook-capture
```

### ページ送りできない

対象アプリを手で操作して、実際にページ送りに効くキーを確認してください。`page-down` で進まない場合は、`Page key` を `Right` や `Space` に変えます。

### 対象ウィンドウが見つからない

`Check Windows` を押して、このツールから見えている対象ウィンドウを確認してください。対象ウィンドウが最小化されている、別の Space にある、まだ起動していない、といった状態では見つからないことがあります。

### 画像の余白や色味がページごとに変わる

対象ウィンドウをフルスクリーン表示にし、ビューア側のテーマ、文字サイズ、余白、表示倍率を固定してください。ページ送り後の描画が間に合わない場合は `Delay` を長くします。
