Tartarus_AHK_v9_PORTABLE_AUDIT_FIX1
==================================

この版は、ユーザー提供の現行 Tartarus_AHK_v9_PORTABLE(2).zip を基準に、
Controller 16 の問題だけでなく、入力・アナログ・常駐・設定保存を横断して再監査した版です。

主な修正
--------
1. 修飾キー単体のソフトウェアリピート禁止
   LControl / LShift / LAlt / Win を押しっぱなしにしても DOWN を連打しません。

2. AHKのグローバルホットキーを全廃
   過去の Ctrl+Alt+1～5 に加え、残っていた Ctrl+Alt+F12 も削除。
   Tartarus自身の出力がAHKの管理用ショートカットを自己発火する経路をなくしました。

3. HyperShiftを複数キー対応に変更
   HYPERを2個以上割り当てても、片方を離しただけでNormalへ戻りません。

4. マウスボタン出力を参照カウント化
   同じマウスボタンを複数の物理キーから保持した場合に、片方を離しても早期UPしません。
   終了時も保持中マウスボタンを明示的にUPします。

5. アナログ共有メモリ再接続修正
   Analog daemonが落ちたり再起動した場合、AHKが古い mmap を握り続けないようにしました。

6. Analog daemonの異常ログ洪水を修正
   提供ZIP内の Tartarus_Analog_Debug.log は 587,757,497 bytes まで増えていました。
   原因は読み出し不能なInterface-1 collectionの read error を高速ループで毎回ログ出力していたことです。
   既知のboot-keyboard collectionを除外し、連続read errorのcollectionを切り離し、エラーログをレート制限し、
   ログ上限も2MiBにしました。

7. Analog daemon / LED daemon の二重起動防止
   Windows named mutex を追加しました。

8. Analog/LEDのInterface 2競合を緩和
   起動順を Analog -> LED -> Mapper に変更。
   LED daemon側からもmode-3 streaming unlockを送るため、Analog daemon再起動時にも復旧しやすくしました。

9. Analog切替時のheld action再発火を防止
   digital入力からanalog入力へ切り替わる際、押しっぱなし中のキーを再実行せずtoken所有権だけ移します。
   MAP / MEDIA / HyperShift / held shortcutの二重発火を避けます。

10. 設定ファイルを厳格検証
    壊れた行・未知のKeymap・無効な物理キー・無効なactionを含むconfigをそのまま採用しません。
    起動時は現在configが不正ならbackupを試します。

11. 設定保存の競合防止
    Settings server側にlockを追加し、UIの保存ボタンも多重送信しないようにしました。

12. 入力ホットパスの同期ディスク書込みを削減
    RAW/DOWN/UP/SEND/REPEATの詳細ログはデフォルトOFFです。
    詳細ログが必要なときだけ、このフォルダに ENABLE_VERBOSE_LOGGING.txt を作成してください。

13. BATをBOMなしASCII + CRLFへ統一
    過去に出た「・ｿ@echo off」を避けます。

14. RUN_SELF_TEST.bat を追加
    Python構文、config、隠しAHK hotkey、修飾キーrepeat guard、daemon mutex等を一括確認します。
    SETUP_PORTABLE.ps1も自動起動登録の前にself-testを実行します。

注意
----
静的検査とPython側の構文/プロトコル単体テストは通していますが、
AutoHotkey + AutoHotInterception + 実Tartarusの最終挙動はWindows実機でしか完全には検証できません。
大会等の前には RUN_SELF_TEST.bat と、メモ帳等での全キー押下確認を行ってください。
