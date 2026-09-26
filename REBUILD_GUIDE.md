# Tartarus Pro Synapse Replacement — REBUILD GUIDE

## 目的
Razer Tartarus Pro を Synapse の代わりに AutoHotkey v2 + AutoHotInterception で制御する。
HyperShift切替時にも、すでに押下中の出力キーを絶対に離さないことが最重要仕様。

## 完成版
v10.1 PORTABLE（動的Keymap管理・終了処理修正版）

このフォルダ一式を保存しておけば、過去チャットやAI側の記憶がなくても再現可能。

## 主要ファイル
- `Tartarus_Main.ahk` — 入力処理本体
- `Tartarus_Config.tsv` — 現在の全キーマップ
- `Tartarus_Config.default.tsv` — v7時点の基準配置
- `Tartarus_LED_Daemon.py` — キーマップ連動RGB
- `Tartarus_Settings_Server.py` — ローカル設定UI
- `Tartarus_Runtime.ps1/.vbs` — 起動/停止/二重起動管理
- `Lib/` — 初回SETUP時に既存AutoHotInterceptionからコピー
- `Logs/` — デバッグログ

## Tartarus Pro デバイス情報
- VID: `0x1532`
- PID: `0x0244`
- keyboard interface IDs were observed as AHI ID 5 / 6
- mouse interface was observed as AHI ID 18
AHIの数値IDは接続環境で変わり得るため、コードではVID/PIDから取得する。

## 物理入力
- 01..20: scan codes 2,3,4,5,6,15,16,17,18,19,58,30,31,32,33,42,44,45,46,57
- Thumb: scan code 56
- D-pad: 328 / 333 / 336 / 331
- Wheel: mouse code 5, state +1/-1

## 入力仕様
- HyperShiftはAHK内部レイヤー。
- レイヤー変更・キーマップ変更で既押下出力を解放しない。
- 物理DOWN時に `ActiveActions` へその時のActionを保存し、物理UP時は保存済みActionを解放する。
- Tartarus側の生リピートには依存しない。
- 500ms後、31ms間隔のソフトウェアtypematic。
- D-pad/Thumbは30ms stable-release debounce。
- Thumbの高速連打を潰さない。
- 設定UI保存後、約300msでマッピング再読込。
- 再読込しても押下中キーのActiveActionsは変更しない。

## キーマップ
初期状態は5種類:
- Keymap 1
- Controller
- clip_studio
- aseprite
- blender

ブラウザUIから最大32個まで新規作成・複製・名前変更・削除できる。
並び順・名前・LED色は `Tartarus_Config.tsv` の `@map` 行が正本。

Normal / HyperShiftを別管理。
正確な現在配置は `Tartarus_Config.tsv` が唯一の正本。

## LED
Tartarus Pro main RGB matrix:
- HID VID/PID 1532:0244
- control usage_page=0x0001 usage=0x0002, interface 2 observed
- transaction id `0x1F`
- class `0x0F`
- custom mode cmd `0x02`, effect `0x08`
- custom frame cmd `0x03`
- matrix 1x21
- full-frame RGB uploadでファームウェアのゆっくりしたStatic遷移を避ける
- LEDデーモンの終了は `Tartarus_Runtime.ps1` だけが担当する
- start/restart/stopは名前付きMutexで直列化し、同時再起動の競合を防ぐ
- 同じキーマップでも「LEDを再同期」で色を再送する

初期色:
- Keymap 1: red
- Controller: green
- clip_studio: blue
- aseprite: purple
- blender: cyan

各KeymapのLED色はブラウザUIのカラーピッカーから変更できる。

Tartarus Pro側面の小型profile indicator LEDは制御できなかったため使用しない。

## 設定UI
`http://127.0.0.1:8765/`

編集可能:
- 01〜20
- Thumb
- D-pad
- Wheel
- Keyboard / shortcut capture
- Mouse buttons
- Keymap switch
- HyperShift
- Media
- Wheel output
- Disable
- Default/raw fallback
- Keymapの新規作成 / 複製 / 名前変更 / 削除
- KeymapごとのLED色

保存形式はTSV。
ブラウザサーバーは127.0.0.1にのみbindする。

## 依存
- Windows
- AutoHotkey v2
- Python 3
- Python `hidapi`
- AutoHotInterception + Interception driver

## 将来AIへ渡すとき
新しいチャットにこのフォルダまたはZIPを渡し、次のように伝える:

> Razer Tartarus Pro用のSynapse代替です。
> REBUILD_GUIDE.mdを読み、Tartarus_Config.tsvを現在の正しいキー配置として扱ってください。
> HyperShift中に既押下キーを離さない仕様、ソフトウェアtypematic、30ms debounce、
> custom-frame LEDを壊さずに続きを修正してください。

過去会話の記憶より、ここに入っているソースと `Tartarus_Config.tsv` を優先すること。
