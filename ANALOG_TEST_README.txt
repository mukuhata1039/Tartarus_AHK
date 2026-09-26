Tartarus Pro Analog Test 2
===========================

TEST1で01-20が反応しなくなる問題を修正。

原因:
- WindowsではTartarus Pro Interface 1が複数HID collectionとして列挙される。
- TEST1はそのうち1 pathだけを開いていたため Report ID 0x06 を受け取れない場合があった。
- さらに0x06を受信していない段階でもAHKへ「アナログ接続中」と通知していたため、
  AHK側が従来の01-20入力を抑止し、キーが完全に死んでいた。

TEST2の修正:
- Interface 1の全HID collectionを開く。
- 64 byte bufferで読み、Report ID 0x06だけを採用する。
- Interface 1を先に開いてからInterface 2へdevice mode 3を送る。
- 0x06を実際に1回受信するまでアナログONLINEにはしない。
- 0x06未受信時は01-20も従来のAutoHotInterception入力を使用する。
- 設定画面では「0x06受信済み」「0x06待機中」「未接続」を区別して表示する。

確認方法:
1. Tartarus_Runtime.vbs で起動。
2. http://127.0.0.1:8765/ を開く。
3. 「押し込み深さ」を開く。
4. 「HID接続中（0x06受信済み）」になることを確認。
5. 01-20を押し、青いraw depthバーが動くことを確認。

0x06が取れなかった場合でも、TEST2では01-20は従来入力で動くのが正常な
フェイルセーフ動作です。詳細は Logs/Tartarus_Analog_Debug.log を参照。


[TEST3 change]
- Actuation slider range expanded from 1.5-3.6 mm to 0.1-3.6 mm.
- 0.1-0.4 mm is an ultra-sensitive range intended for near-touch actuation.
- Hysteresis is now scaled for shallow thresholds instead of always subtracting raw 20.
