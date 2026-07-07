# RTL 修正プラン: cross-card レイテンシの符号なし切り詰め破壊

> **★ 真因解決 (2026-07-07)**: min=0 / 広スプレッド / 見かけの ~20-tick 方向非対称の
> **本当の原因は、単一スレッド daemon の servo 飢餓**だった。Web GUI ダッシュボードが
> `sfp.info` を ~1Hz でポーリングし、その RPC が I2C bit-bang(~0.58s)を main ループ
> 上で同期実行 → cross-card `lat_correction` servo を最大 565ms 飢餓 → ~1.6ppm skew で
> correction が stale 化 → レイテンシが min=0/max~200 に散乱。**修正**: servo と SFP I2C
> を各々専用スレッドに分離(daemon、`servo_thread_fn`/`sfp_refresh_thread_fn`、
> `g_servo_lock`)。HW 検証で全 32 cross-card flow min>0・loss=0、真の非対称は ~3 ticks
> (sync-path capture のみ)。**RTL 改修も per-session 校正も不要**。以下の Phase 1
> (clamp)は防御的に有効(負サンプルのクランプ)なので維持。Phase 2 の -C は残すが、
> 真の非対称 ~3 ticks では実質不要。詳細は CHANGELOG / daemon.md / メモリ
> xcard-latency-wrap-bug。

## 症状（実機 pwhost1, 2枚 DAC cross-connect, 12h soak 2026-07-06）

cross-card レイテンシが**片方向だけ**壊れる:

| 方向 | flow.stats offset_ticks | min / avg / max | 状態 |
|---|---|---|---|
| card0→card1 (rx=card1) | **+176,038,370** | 0 / ~0-1 / 0xFFFFFFFF | 壊れ |
| card1→card0 (rx=card0) | **−176,038,370** | 34 / 63 / 213 | 正常 |

`lost=0` 両方向 = パケットロスではなく**レイテンシ測定表示のみ**の問題。jitter も同様に
`jitter_max=0xFFFFFFFF` に化ける。offset_ticks は ±同値でサーボは正しく追跡できている。

## 真因（2層）

RTL: `rtl/phase3/pw_test_rx_checker_bram.sv`（アクティブは `pw_data_plane_axis.sv:669`
がインスタンス化する BRAM 版。legacy `pw_test_rx_checker.sv` も同構造）。

```
181: automatic logic [63:0] lat = (timestamp_i + lat_correction_i) - key_i.test_tx_timestamp;
182: automatic int          b   = log2_bucket(lat);   // 最上位セットbit → 負値で~63に飽和
217: lat32  = s1_lat[31:0];                            // ★符号なし32bit切り詰め
232: nr[OFF_SUML +: 64] = rec[...] + s1_lat;           // sum は64bit（負値で桁化け）
234: if (lat32 < curmin) ...MINL = lat32;              // 符号なし比較
235: if (lat32 > curmax) ...MAXL = lat32;              // 負値→0xFFFF_FFxx→max=0xFFFFFFFF
239: jd = (lat32 >= prev) ? (lat32-prev) : (prev-lat32); // jitterも汚染
```

負サンプルを破棄/クランプする処理は**無い**。min は 0xFFFFFFFF シード、max は 0 シード。

### 層A（RTL堅牢性バグ）— 符号なし切り詰め
補正後レイテンシ `lat` は 64bit 二の補数で**負になりうる**。負のとき `lat[31:0]` が
0xFFFF_FFxx（巨大な符号なし値）になり、max=0xFFFFFFFF に張り付き、log2_bucket も最上位
バケットに飽和、sum も桁化け。**負値をゼロにクランプすれば表示のガベージは消える。**

### 層B（精度/校正バグ）— 方向非対称バイアス
数学的には両方向とも真値 ~63 ticks になるはず（offset_ticks は共有エッジで測った純カウンタ
オフセットで、frame の rx_now/tx_stamp と相殺するはず）。しかし bad 方向は 0 中心 = **真値
より約63 ticks 過補正**されている。原因は、GPIO sync のオフセットが **dp_clk(コア)ドメインの
共有エッジ**で測られるのに対し、frame の TX スタンプは **MAC TX ドメイン**(pw_ts_insert +
gray CDC)、RX スタンプは **MAC RX ドメイン**(RX wire-stamp)で捕捉され、各カードの
TX側/RX側キャプチャ点のパイプライン/CDC バイアスが**方向で非対称**に効くため。J5 ケーブル伝搬
(<1m=数ns=<1tick)では説明できない大きさ(~63tick=~400ns)なので、ドメイン間キャプチャ点の
差が主因。これは校正で吸収すべき静的な項。

## 修正プラン

### Phase 1 — 層A: RTL クランプ（小・安全・ガベージ表示を即殺）
`pw_test_rx_checker_bram.sv`（+ parity で `pw_test_rx_checker.sv`）:

1. `lat` を signed として扱い、負なら 0 にクランプ、>32bit なら 0xFFFFFFFF に飽和:
   ```systemverilog
   wire signed [63:0] lat_s = $signed(lat);
   wire [63:0] lat_clamped = lat_s < 0 ? 64'd0
                           : (|lat[63:32] ? 64'hFFFFFFFF : lat);
   // s1_lat <= lat_clamped; log2_bucket(lat_clamped); lat32 = lat_clamped[31:0];
   ```
   これで min/max/sum/histogram/jitter すべてが健全な値になる（過補正方向は
   min=0/avg≈0/max≈小、0xFFFFFFFF は出ない）。
2. 診断: **負クランプ発生カウンタ**を追加（校正ズレを可視化）。per-flow は BRAM REC_W 拡張=
   NUM_FLOWS倍のコスト大なので、まず**グローバル1本の CSR カウンタ**で開始（LUT/BRAM 節約）。
3. sum は64bitのまま（クランプ後は非負なので桁化けしない）。avg=sum/samples はソフト側据置。

**検証**: Verilator sim（`sw/tests/` の checker テスト）に負の補正を食わせ、min=0/max=小/
neg-count++ をアサート。既存の正常ケースが不変であること。

**LUTコスト**: 比較器数個＋グローバルカウンタ。現状 LUT 94.94% と逼迫（[[dp-clk-timing-lessons]]）
なので post-route timing/util を必ず確認。per-flow 診断は入れない。

### Phase 2 — 層B: 方向非対称バイアスの校正（精度回復） — IMPLEMENTED (SW)
**RTL 不要**: checker は既に `lat = (rx_ts + lat_correction) − tx_ts` を計算し、`lat_correction`
は daemon サーボが書くので、**サーボ/prime が書く補正値に校正バイアスを畳み込む** SW 実装。
1. **特性評価**: pwhost1 で同一フローの両 cross-card 方向を測定。非対称 `(dir_ab − dir_ba)/2`
   が校正項（実測: card1→card0 avg≈63, card0→card1 avg≈19 → cal ≈ 22 ticks）。
2. **適用**: daemon フラグ `-C CAL_TICKS`（signed, 6.4ns/tick, 既定0）。`servo_lat_correction`
   と `prime_lat_correction` が corr に `xcard_cal_bias(m)` を加算。card-id 順で antisymmetric
   （tx<rx: +cal, tx>rx: −cal）。2カードペアで厳密; >2カードで per-card skew があれば per-card
   テーブルが必要（コメントに明記）。
3. **検証**: 両方向が真の片道レイテンシ（≈41 ticks）を ±jitter 内で一致して表示すること
   （pwhost1、byte-counter ビルドと同一 HW セッションで検証）。

## 段階・リスク
- Phase 1 だけで「壊れ表示(0xFFFFFFFF)」は消え、soak の latency 判定が使える状態になる
  （精度は Phase 2 まで片方向 ~63tick 低め）。RTL 変更=Vivado リビルド必須。
- Phase 2 は実機特性評価が要るため後続。CSR 追加時は [[docs-code-parity-rule]] に従い
  rpc/daemon/docs 同時更新。
- 両 checker 変種の parity を保つ（legacy 版もクランプ）。
- マージ前 HW 検証（[[hw-test-before-merge]]）: pwhost1 で両方向とも 0xFFFFFFFF が出ない
  こと＋ arran 単カードで既存 latency 不変を確認。

関連: [[xcard-latency-wrap-bug]] [[xcard-latency-hw-correction-plan]] [[gpio-cross-card-sync]]
[[rx-wire-stamp-plan]]
