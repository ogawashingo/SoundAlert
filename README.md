# SoundAlert for macOS

iOSの「カスタムサウンド認識」のように、特定のアラート音（Microsoft Teamsの通知音・着信音など）をUSBカメラマイク等でリアルタイムに聴き取り、Discordチャンネル（Webhook）へスマホ通知を送るmacOSネイティブアプリです。

## 主な特徴

- **iOS風カスタムサウンド学習**: 別PCなどから鳴る実際の通知音を1〜3回マイク録音して音響テンプレート（40バンド対数メルスペクトル）として登録可能
- **環境ノイズ遮断モード**: 最小音量ゲート（dB）とスペクトルホワイトニングにより、空調やPCファンなどの定常ノイズを自動カット
- **超低CPU負荷**: Apple SiliconのSIMD命令（`Accelerate` / `vDSP`）およびウィンドウ非表示時の描画停止により、バックグラウンド常駐時のCPU負荷は約0.1%〜0.3%
- **Discord Webhook連携**: 検知時にメンション（`@here` / `@everyone`）および一致度スコア付きの通知を送信
- **メニューバー常駐**: メインウィンドウを閉じてもメニューバーから監視の継続・切り替えが可能

## ビルドと起動方法

Xcode Command Line Tools が入った macOS（Apple Silicon）で以下のコマンドを実行します：

```zsh
zsh build.sh
open SoundAlert.app
```

## データ保存先（Git管理外）

設定（Discord Webhook URL等）や録音した音声データは、リポジトリ内ではなく以下のローカルディレクトリに保存されます：

```text
~/Library/Application Support/SoundAlert/
```
