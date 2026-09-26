Tartarus SOCD / Last Input Wins
================================

この版は GitHub main（AUDIT FIX1）を基準に、Rapid Triggerは追加せず、
WASDの後入力優先（Last Input Wins）だけを追加した版です。

対象となる物理キー
------------------
08 = W
12 = A
13 = S
14 = D

動作
----
Aを保持中にDを押す: Aを即OFF、DをON
Dを離してAをまだ保持している: DをOFF、Aを自動復帰
W/Sも同様です。

安全策
------
・SOCD対象は上記4物理キーが単独の W/A/S/D に割り当てられている場合だけ。
・Ctrl+A等のショートカット、他の物理キーに置いたA/D/W/Sには作用しません。
・SOCD対象のWASDはソフトウェアTypematicを使いません。ゲームではDOWN保持状態を維持します。
・アナログ入力／固定作動点／LED／HyperShiftその他には変更を入れていません。
・Rapid Triggerはこの版には入っていません。

確認
----
RUN_SELF_TEST.bat を実行し、FAIL=0を確認してください。
実機ではメモ帳やキーテスターで A保持→D→D離し→A復帰 を確認してください。
