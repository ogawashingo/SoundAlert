# SoundAlert

iOSの「カスタムサウンド認識」のように、特定のアラート音（チャイム・各種通知音・着信音など）をマイクでリアルタイムに聴き取り、Discordチャンネル（Webhook）へスマホ通知を送るmacOSネイティブアプリです。

## 主な特徴

- **iOS風カスタムサウンド学習**: 別PCなどから鳴る実際の通知音を1〜3回マイク録音して音響テンプレート（40バンド対数メルスペクトル）として登録可能
- **環境ノイズ遮断モード**: 最小音量ゲート（dB）とスペクトルホワイトニングにより、空調やPCファンなどの定常ノイズを自動カット
- **超低CPU負荷**: Apple SiliconのSIMD命令（`Accelerate` / `vDSP`）およびウィンドウ非表示時の描画停止により、バックグラウンド常駐時のCPU負荷は約0.1%〜0.3%
- **Discord Webhook連携**: 検知時にメンション（`@here` / `@everyone`）および一致度スコア付きの通知を送信
- **メニューバー常駐**: メインウィンドウを閉じてもメニューバーから監視の継続・切り替えが可能

## ビルドと起動方法

Xcode Command Line Tools が入った macOS 14.0 以降（Apple Silicon）で以下のコマンドを実行します：

```zsh
zsh build.sh
open SoundAlert.app
```

## テストの実行

Webhook URL 検証・パストラバーサル対策・音響特徴抽出／類似度計算のユニットテストを実行できます：

```zsh
zsh test.sh
```

## データ保存先（Git管理外）

- **Discord Webhook URL**: macOS の **Keychain**（`com.soundalert.macos`）に暗号化保存されます（`settings.json` には平文保存されません）
- **その他の設定・録音した音声データ**: リポジトリ内ではなく以下のローカルディレクトリ（パーミッション `0700` / `0600`）に保存されます：

```text
~/Library/Application Support/SoundAlert/
```
