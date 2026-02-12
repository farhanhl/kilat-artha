# Changelog

## 2026-02-12
- Initial implementation `KilatArthaEA.mq4`.
- Added multi-pair state handling and per-symbol new-bar logic.
- Added OB + BOS detection with fractal swing approach.
- Added trend filter, spread guard, and pip conversion helpers.
- Added martingale/averaging + basket profit/loss close logic.
- Added Anti-MC module (margin guard, panic close, max DD, dynamic martingale cap, orders/lots limits).
- Added README with setup, assumptions, and MT4 multi-symbol testing limitations.
- Added OB expiry (`OB_Max_Bars_Valid`) and OB invalidation-by-close with optional pip buffer.
- Added session filter (`Enable_Session_Filter`, start/end server hour).
- Added adaptive spread control per symbol (`Maximum_Spread_Per_Symbol`) with XAU fallback multiplier.
