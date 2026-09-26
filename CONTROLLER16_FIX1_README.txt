Controller 16 FIX1

修正内容:
1) Controller / Normal / 16 = LControl のような「修飾キー単体」に
   ソフトウェアオートリピートを掛けないよう修正。
   旧版は約31msごとに LControl DOWN を再送しており、これが異常動作の原因になり得た。

2) 同じ問題を LShift / LAlt / LWin / 右側修飾キーにも共通修正。
   Ctrl+d のような「修飾キー + 通常キー」は通常キー側だけ従来どおりリピート可能。

3) 旧デバッグ用の Ctrl+Alt+1～5 グローバルKeymap切替を削除。
   Tartarus自身が生成したキー出力でKeymapが自己切替する経路を封止。

ベース:
ユーザー提供 Tartarus_AHK_v9_PORTABLE(2).zip
