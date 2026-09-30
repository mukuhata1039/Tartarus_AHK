Tartarus STARTUP FIX1
=====================

症状:
- Windowsへログオンした直後、Tartarusのタスクトレイ常駐が起動しないことがある。

原因:
- 旧構成は HKCU Run から Tartarus_Runtime.vbs を1回だけ即実行していた。
- ログオン直後はExplorer/USB HID/AutoHotInterception/出力キーボードの列挙がまだ完了していない場合があり、
  Tartarus_Main.ahk がその1回で起動失敗すると再試行されなかった。
- また、フォルダを更新しただけでSETUPを再実行していない場合、HKCU Runが古いテストフォルダを指し続けることがある。

修正:
- Tartarus_Autostart.vbs/ps1 を追加。ExplorerとHIDが落ち着くまで少し待ち、起動確認できるまで再試行。
- Tartarus_Runtime.ps1側にもmapper起動の再試行を追加。
- SETUP_PORTABLE.ps1は新しいAutostart launcherをHKCU Runへ登録。
- REGISTER_AUTOSTART.bat を追加。現在のフォルダを自動起動先として1クリックで再登録可能。
- 他アプリのスタートアップ登録には一切触れない。

既存環境への適用:
1. この版を現行フォルダへ上書き。
2. REGISTER_AUTOSTART.bat を1回実行。
3. 再起動してタスクトレイを確認。

C:ドライブ必須ではありません。現在の E:\app\Tartarus_AHK_v9_PORTABLE のような別ドライブで問題ありません。
