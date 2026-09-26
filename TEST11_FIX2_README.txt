Tartarus Pro TEST11 FIX2

修正点:
- TEST11のUI自体はv11.3だったが、旧ポータブルフォルダのv11.2設定サーバーが8765番ポートに残る問題を修正。
- Runtimeの停止対象を「現在フォルダの絶対パス」ではなくTartarus各スクリプト名で判定。
- restart時に古いTartarus_Main / Settings_Server / LED_Daemon / Analog_Daemonを全て停止してから、このフォルダ版だけを起動。
- 確認しやすいようUI表示を v11.3.1 に変更。
- レイヤー別3灯インジケーター機能はTEST11のまま維持。

確認:
SETUP_PORTABLE.bat実行後、http://127.0.0.1:8765/ の左上が UI v11.3.1 になり、Normal / HyperShift の右側に「インジケーター 赤 緑 青」が表示される。
