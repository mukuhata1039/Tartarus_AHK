TEST11 FIX3 STARTUP SAFE

修正内容:
- SETUP_PORTABLE.ps1 実行時、既存のHKCU RunキーをNew-Item -Forceで
  作り直さないよう修正しました。
- SoundSwitch、NZXT CAM、Google Drive、LINEなど、同じRunキーにある
  他アプリの自動起動登録を保持します。
- キーマップ、アナログ入力、LED、レイヤー表示には変更を加えていません。

注意:
- すでに消えた他アプリの登録は、別のスタートアップ復旧ツールで戻してください。
