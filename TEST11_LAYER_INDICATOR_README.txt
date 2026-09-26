Tartarus Pro TEST11 - レイヤー別3灯インジケーター

- 右側の3個のインジケーターを、Keymapごとの Normal / HyperShift ごとに個別ON/OFFできます。
- 設定UIの Normal / HyperShift 切替ボタンの右側に「インジケーター 赤 / 緑 / 青」を追加。
- チェックON=点灯、OFF=消灯。明るさ設定はありません。
- 設定は Tartarus_Config.tsv の @indicator 行に保存されます。
- HyperShiftのON/OFF時にもLED状態ファイルを即更新するため、押している間だけ別の点灯パターンへ切り替えられます。
- TEST10で実機確認できた LED ID 0x0B / class 0x0F / cmd 0x02 を使用。
