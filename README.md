# KilatArthaEA (MT4)

Expert Advisor MQL4 multi-pair untuk konsep Order Block + Trend Filter + Grid/Martingale + Anti-Margin-Call.

## File
- `KilatArthaEA.mq4`: EA utama.
- `README.md`: panduan setup, input, asumsi.
- `CHANGELOG.md`: ringkasan perubahan.

## Instalasi
1. Buka MT4 `File -> Open Data Folder`.
2. Salin `KilatArthaEA.mq4` ke `MQL4/Experts/`.
3. Restart MT4 atau klik kanan `Navigator -> Refresh`.
4. Attach EA ke chart mana saja (EA tetap memproses banyak simbol dari input `Symbols`).
5. Aktifkan `AutoTrading`.

## Catatan Broker / Simbol
- Target broker: HFM.
- Default simbol: `EURUSD,GBPUSD,USDJPY,XAUUSD`.
- Pastikan nama simbol sesuai broker (contoh suffix seperti `.m`, `pro`, dll jika ada).
- EA akan `SymbolSelect(..., true)` otomatis; tetap disarankan membuka/menampilkan simbol di Market Watch.

## Ringkasan Logika
- Multi-pair dengan loop simbol dari input `Symbols`.
- New bar per simbol menggunakan `iTime(sym, Timeframe, 0)`.
- Deteksi Order Block berbasis BOS + swing fractal `L=2`.
- Filter tren HTF menggunakan EMA (default `MN1`, period `200`).
- Entry dibatasi `MaxNewTradesPerBar` per simbol.
- Martingale/averaging per arah, cap level efektif dari Anti-MC dynamic cap.
- Basket close per simbol berdasarkan profit uang / optional cut-loss uang.
- Anti-MC: margin level guard, panic close, max drawdown guard, max orders/lots guard.
- Session filter optional berdasarkan jam server broker.
- OB validity enhancement: expiry berbasis umur OB + invalidasi jika close menembus OB.
- Adaptive spread per simbol via override map.

## Penjelasan Algoritma

Bagian ini menjelaskan alur keputusan EA secara deterministik, dari level global sampai level order.

## Penjelasan Algoritma

Bagian ini dibuat khusus untuk reviewer.

### Tujuan Sistem
EA ini mencari Order Block yang valid, menunggu retest, lalu entry hanya jika konteks struktur harga dan risiko akun mendukung.

### Alur Sederhana
1. EA memantau semua pair dalam `Symbols`.
2. Setiap bar baru timeframe sinyal:
   - cek spread,
   - cek jam trading (jika session filter aktif),
   - cek kondisi akun (margin, drawdown, batas order/lot).
3. EA mencari OB bullish/bearish yang masih valid.
4. Jika ada retest dan konfirmasi candle, EA entry sesuai aturan arah.
5. Jika posisi sudah ada, EA bisa tambah posisi (averaging/martingale) sesuai batas level dan risk cap.
6. Saat profit basket simbol mencapai target uang, basket ditutup.
7. Jika floating loss basket melewati batas cut-loss (opsional), basket ditutup.
8. Jika margin masuk zona darurat, EA menjalankan panic close.

### Definisi Praktis Yang Dipakai
1. Bullish OB: candle bearish terakhir sebelum dorongan naik yang mematahkan swing high.
2. Bearish OB: candle bullish terakhir sebelum dorongan turun yang mematahkan swing low.
3. Retest: harga kembali menyentuh zona OB.
4. Konfirmasi:
   - BUY: candle penutup bullish atau close di atas mid OB.
   - SELL: candle penutup bearish atau close di bawah mid OB.

### Kapan OB Dibatalkan
1. OB sudah terlalu lama (expired).
2. OB sudah ditembus close secara invalid (melewati batas OB + buffer).
3. Ukuran OB terlalu kecil (gagal filter pips/ATR).
4. Jarak ke OB sebelumnya terlalu dekat (jika mode distance aktif).

### Logika Averaging / Martingale
1. Entry pertama selalu butuh sinyal OB valid.
2. Posisi tambahan hanya diizinkan jika martingale aktif dan belum melewati cap.
3. Jika pakai jarak averaging:
   - BUY ditambah saat harga turun melawan entry terakhir sejauh jarak minimum.
   - SELL ditambah saat harga naik melawan entry terakhir sejauh jarak minimum.
4. Jika jarak averaging = 0, tambahan posisi hanya saat muncul sinyal OB baru.

### Proteksi Risiko (Anti-MC)
1. Blok entry baru jika margin level di bawah batas aman.
2. Batasi jumlah order dan total lot (global EA dan per simbol).
3. Saat margin kritis:
   - bisa tutup semua posisi EA, atau
   - tutup basket simbol terburuk dulu sampai margin pulih.
4. Jika drawdown equity dari puncak melewati batas, entry diblok (dan bisa close all jika diaktifkan).

### Inti Filosofi
1. Entry wajib berbasis struktur + retest + konfirmasi, bukan random tick.
2. Averaging tetap dibatasi ketat oleh level, lot cap, dan kondisi akun.
3. Prioritas utama: mencegah margin call, bukan memaksa frekuensi entry tinggi.

### 1) Inisialisasi (`OnInit`)
1. Parse `Symbols` menjadi array simbol unik, trim spasi, abaikan token kosong.
2. Alokasikan state per simbol:
   - `lastBarTime`
   - `tradesOpenedThisBar`
   - `lastOBMidBuy`, `lastOBMidSell`
   - `lastEntryPriceBuy`, `lastEntryPriceSell`
3. `SymbolSelect(symbol, true)` untuk memastikan simbol aktif di Market Watch.
4. Parse override spread per simbol dari `Maximum_Spread_Per_Symbol` (format `SYM=points,...`).
5. Set `peakEquity` awal = `AccountEquity()`.

### 2) Loop Utama (`OnTick`)
Urutan eksekusi:
1. Update `peakEquity` jika equity baru lebih tinggi.
2. Jalankan guard global Anti-MC:
   - panic close jika margin level di bawah ambang panic.
   - max drawdown guard (blok entry baru + optional close all).
3. Loop semua simbol hasil parsing `Symbols`, panggil `ProcessSymbol(sym)`.

### 3) Proses Per Simbol (`ProcessSymbol`)
Urutan validasi:
1. Validasi harga tersedia (`MODE_BID`/`MODE_ASK` > 0), jika tidak: skip.
2. Jalankan basket close by money untuk simbol itu:
   - close semua order EA simbol jika profit basket >= target.
   - optional cut-loss basket jika minus melewati threshold.
3. New-bar gate:
   - `t = iTime(sym, Timeframe, 0)`
   - jika `t != lastBarTime[sym]`: reset counter bar dan lanjut.
   - jika bukan new bar: stop (entry logic bar-based).
4. Spread gate:
   - ambil `MODE_SPREAD` (points).
   - bandingkan dengan `MaxSpreadForSymbol(sym)` (adaptive/override).
5. Session gate (opsional):
   - jika di luar window jam server: blok entry baru.
6. Guard global entry (Anti-MC/news/DD):
   - block jika margin level di bawah `AntiMC_MinMarginLevelPercent`.
   - block jika DD melewati batas `AntiMC_MaxEquityDrawdownPercent`.
   - block saat news window aktif (placeholder saat ini selalu false).
7. Kumpulkan statistik basket simbol (count buy/sell, lots, profit, last entry price).
8. Bangun sinyal BUY dan SELL secara independen (OB + filter + retest + konfirmasi).
9. Coba eksekusi BUY lalu SELL melalui `ProcessDirection`, tetap hormati `MaxNewTradesPerBar`.

### 4) Deteksi Struktur & Order Block

#### 4.1 Swing (Fractal-like)
- Konstanta internal: `L=2`.
- Swing high pada bar `i` jika `High[i]` adalah maksimum dalam rentang `i-L .. i+L`.
- Swing low analog.

#### 4.2 BOS
- Buffer BOS:
  - `bufferPrice = max(spreadPoints*Point, 2*Point)`.
- Bullish BOS: `Close > latestSwingHigh + bufferPrice`.
- Bearish BOS: `Close < latestSwingLow - bufferPrice`.

#### 4.3 Definisi OB
- Bullish OB:
  - cari candle bearish terakhir sebelum impuls bullish yang memecah swing high.
  - zona OB = `[Low, High]` candle bearish tersebut.
- Bearish OB:
  - cari candle bullish terakhir sebelum impuls bearish yang memecah swing low.
  - zona OB = `[Low, High]` candle bullish tersebut.

#### 4.4 Validitas OB Tambahan
- OB expiry:
  - umur OB (bar sejak candle OB) tidak boleh melebihi `OB_Max_Bars_Valid` (jika >0).
- OB invalidation by close:
  - BUY invalid jika ada close setelah OB yang menembus `OB_Low - buffer`.
  - SELL invalid jika ada close setelah OB yang menembus `OB_High + buffer`.
  - buffer = `OB_Invalidation_Buffer_Pips * PipPoint(sym)`.
- Filter ukuran OB:
  - opsi ketebalan OB minimum dalam pips; atau
  - jarak mid OB saat ini terhadap mid OB sebelumnya (per simbol+arah).
- Filter ATR D1:
  - wajib `OB_Thickness >= Min_OBtoOB_in_Daily_ATR * ATR_D1`.

### 5) Trigger Entry
Sinyal valid jika semua terpenuhi:
1. OB valid ditemukan.
2. Retest:
   - candle tertutup terakhir (`shift=1`) overlap dengan zona OB.
3. Konfirmasi:
   - BUY: close bullish atau close > OB mid.
   - SELL: close bearish atau close < OB mid.
4. Lolos filter trend HTF (jika `Ignore_Counter_Trend=true`):
   - block BUY saat trendDown.
   - block SELL saat trendUp.
5. Lolos rule side/hedging/opposite restrictions.

### 6) Manajemen Posisi & Martingale
1. Level arah:
   - `level = countDirection - 1`.
2. Effective martingale cap:
   - `min(Maximum_Martingale, dynamicCapByMargin)` jika dynamic cap aktif.
3. Kondisi tambah order:
   - jika belum ada posisi arah tersebut: boleh open hanya jika fresh signal.
   - jika sudah ada posisi:
     - martingale OFF: tidak averaging.
     - martingale ON:
       - `Averaging_Distance_Pips > 0`: tambah saat harga bergerak berlawanan dari last entry sejauh jarak ini.
       - `Averaging_Distance_Pips == 0`: tambah hanya saat fresh signal baru muncul.
4. Lot:
   - base lot auto/fixed sesuai input.
   - lot level-n = `baseLot * Martingale_Multiplier^n`.
   - normalisasi ke min/max/step broker.

### 7) Proteksi Anti-MC Sebelum Open Order
Sebelum `OrderSend`, EA memaksa:
1. `AntiMC_MaxTotalOrdersEA`
2. `AntiMC_MaxOrdersPerSymbol`
3. `AntiMC_MaxLotsTotal`
4. `AntiMC_MaxLotsPerSymbol`
5. Jika lot melebihi sisa quota lots:
   - lot diturunkan ke sisa quota.
   - jika setelah normalisasi < min lot broker: order dibatalkan.

### 8) Eksekusi & Retry
- Open market order via `OrderSend` dengan:
  - retry hingga 3x untuk error transient (`TRADE_CONTEXT_BUSY`, `REQUOTE`, `SERVER_BUSY`, `PRICE_CHANGED`).
- Close order juga retry logic serupa.
- EA hanya mengelola order dengan `MagicNumber` yang sama.

### 9) Panic Close & Drawdown Guard
- Margin level:
  - `marginLevel = Equity/Margin*100` jika `Margin>0`, else dianggap sangat tinggi.
- Panic close:
  - trigger jika `marginLevel < AntiMC_PanicCloseMarginLevelPercent`.
  - mode A: close semua order EA.
  - mode B: close basket simbol terburuk berulang hingga margin pulih atau order habis.
- Max DD guard:
  - `drawdown% = (peakEquity - equity)/peakEquity * 100`.
  - jika melewati threshold: block entry baru + optional close semua order EA.

### 10) Catatan Audit Teknis
Untuk audit ahli, titik verifikasi utama:
1. Konsistensi basis bar (semua sinyal entry dievaluasi pada new bar per simbol).
2. Potensi look-ahead pada deteksi swing/BOS lintas shift.
3. Validitas definisi retest (menggunakan candle `shift=1`, bukan intrabar tick touch).
4. Interaksi rule opposite-order vs martingale level lawan.
5. Dampak spread adaptif per simbol pada frekuensi entry.

## Input Penting
- `Symbols`: daftar simbol dipisah koma.
- `Timeframe`: timeframe sinyal OB/entry (default `H1`).
- `Maximum_Spread`: batas spread dalam **points** (MODE_SPREAD).
- `Enable_Adaptive_Spread_Per_Symbol`, `Maximum_Spread_Per_Symbol`, `Adaptive_Spread_Multiplier_XAU`:
  - memungkinkan spread limit berbeda per simbol.
  - format override: `SYM=points,SYM2=points` (contoh `XAUUSD=80,USDJPY=35`).
- `OB_Max_Bars_Valid`: umur maksimum OB (dalam bar timeframe sinyal). `<=0` berarti nonaktif.
- `Enable_OB_Invalidation_By_Close`, `OB_Invalidation_Buffer_Pips`: invalidasi OB jika close menembus zona OB (+ buffer).
- `Enable_Session_Filter`, `Session_Start_Hour_Server`, `Session_End_Hour_Server`: batasi entry ke window jam server.
- Semua input `*_Pips` dikonversi dengan helper pip-point per simbol.
- `Timeframe_Trend` + `Trend_EMA_Period`: filter tren HTF.
- `Enable_Martingale`, `Martingale_Multiplier`, `Maximum_Martingale`.
- `Averaging_Distance_Pips`:
  - `0`: averaging hanya saat sinyal OB fresh muncul lagi.
  - `>0`: averaging saat harga bergerak berlawanan sejauh jarak tersebut.
- `AntiMC_*`: guard margin, drawdown, max order, max lots, panic close.

## Asumsi Implementasi
1. Eksekusi entry baru dilakukan pada **new bar** timeframe sinyal per simbol.
2. Retest OB dievaluasi dari range candle tertutup terakhir (`shift=1`) yang menyentuh zona OB.
3. Konfirmasi default:
   - BUY: close bullish atau close > OB mid.
   - SELL: close bearish atau close < OB mid.
4. `Min_OBtoOB_in_Daily_ATR` diterapkan sebagai filter ketebalan OB terhadap ATR D1.
5. Jika `OBtoOB_UseDistanceBetweenOBs=true`, jarak dibandingkan ke OB mid terakhir per simbol+arah yang lolos filter/sinyal.
6. Placeholder news filter: `IsHighImpactNewsNow(sym)` saat ini selalu `false`.
7. EA hanya memproses order market `OP_BUY/OP_SELL` dengan `MagicNumber` yang sama (tidak menyentuh manual trade / EA lain).
8. Session filter memakai jam server broker (`TimeCurrent()`), dengan interval `[start, end)` dan dukung sesi lintas tengah malam.

## Anti-MC Behavior
- Jika `marginLevel < AntiMC_MinMarginLevelPercent`: blok order baru.
- Jika `marginLevel < AntiMC_PanicCloseMarginLevelPercent`:
  - `AntiMC_CloseAllEAOnPanic=true`: close semua order EA.
  - `false`: close basket simbol terburuk berurutan sampai pulih / order habis.
- Peak equity dilacak sejak EA start; saat DD >= `AntiMC_MaxEquityDrawdownPercent`:
  - order baru diblok.
  - optional close semua order EA jika `AntiMC_CloseEAOnMaxDD=true`.

## Logging
- Prefix umum: `[KilatArthaEA][SYMBOL]`.
- Event Anti-MC: `[KilatArthaEA][AntiMC]`.
- Alasan skip dicetak (spread, counter-trend, filter OB/ATR, cap martingale, cap anti-MC, dll).

## Testing
- Compile di MetaEditor MT4 (`Build`) dan pastikan tanpa error.
- Uji forward pada akun demo HFM terlebih dahulu.
- MT4 Strategy Tester memiliki keterbatasan backtest multi-symbol dalam satu EA; untuk validasi perilaku multi-pair, forward test sangat direkomendasikan.

## Disclaimer
EA ini tidak menjamin profit. Gunakan manajemen risiko yang ketat dan lakukan uji menyeluruh sebelum live.
