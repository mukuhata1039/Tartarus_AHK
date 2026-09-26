Tartarus AHK v10.1.4 DUAL LED + LAYER INDICATOR

Razer Synapseから完全移行する手順
1. Windowsの「設定」→「アプリ」→「インストールされているアプリ」を開く。
2. 「Razer Synapse」をアンインストールする。
   Razerのアンインストーラーが開いたら、Synapseと不要なRazerソフトウェアを削除する。
3. Windowsを再起動する。
4. このZIPを最終的に置きたい場所へ展開する。
5. SETUP_PORTABLE.bat を1回実行する。

注意
- デバイスマネージャーからTartarus本体を削除しない。
- AutoHotInterception / Interceptionドライバー / AutoHotkeyは削除しない。
- この版はRazerAppEngineを勝手に強制終了しない。
- Synapseがまだ起動している場合、安全のためマッパーの起動を拒否する。

使い方
1. このZIPを、最終的に置きたい場所へ展開する。
   例: D:\Tools\Tartarus
2. SETUP_PORTABLE.bat を1回実行。
3. 以後はWindowsログイン時に自動起動。

ポイント
- Tartarus用ファイルは展開したこのフォルダ内で完結。
- C:\Tools\AutoHotInterception へのTartarusファイル配置は廃止。
- 初回セットアップ時、旧v8の最新 Tartarus_Config.tsv があれば自動移行。
- 旧C:\Tools\AutoHotInterception から削除するのは Tartarus_* 関連だけ。
  AutoHotInterception本体/Lib/Interceptionドライバは削除しない。
- 自動起動はスタートアップフォルダではなく HKCU Run を使用。
- Logs フォルダもこのフォルダ内。
- 設定画面: http://127.0.0.1:8765/
- トレイ右クリック -> 設定を開く でも開ける。
- v9.1: 再起動時にLED制御だけ停止する競合を修正。
- v10: ブラウザからKeymapの新規作成・複製・名前変更・削除・LED色変更に対応。
- Keymapは最大32個。追加情報も Tartarus_Config.tsv に保存される。
- v10.1: トレイの「終了」がAHKプロセス検出失敗時に効かない問題を修正。
- v10.1.1: Synapse非依存版。RazerAppEngineの強制終了を廃止し、起動競合時は安全停止。
- FIX3: SETUP実行時に、他アプリの自動起動登録を消してしまう問題を修正。
- v10.1.2: キーマップごとに上段LED色・下段LED色を個別指定できるように変更。
- v10.1.4: 右側3個のインジケーターを、KeymapごとのNormal / HyperShiftごとに赤・緑・青それぞれON/OFFできるように変更。

別ドライブ/別フォルダへ移動する場合
1. PREPARE_TO_MOVE.bat
2. フォルダを移動
3. 移動先で SETUP_PORTABLE.bat

重要
AutoHotInterceptionのInterceptionドライバ自体はWindowsへインストールされている必要がある。
v10はアプリ一式・設定・AHIのAHKライブラリをポータブルフォルダへ集約する方式。
