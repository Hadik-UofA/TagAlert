# Test logs

CSV logs written by the app (one row per event, times in UTC). Nearby devices' broadcast names are replaced with `[redacted]`; nothing else is changed. Identifiers are iOS-assigned and AirTag addresses rotate, so IDs are not stable across days.

| File | Build | Test |
|---|---|---|
| `tagalert_log_20261101_222156.csv` | - | First live scans (zero Apple manufacturer data) |
| `tagalert_log_20261101_225048.csv` | - | First live scans |
| `tagalert_log_20261101_231617.csv` | - | FD44 filter test (cached false detections; filter removed) |
| `tagalert_log_20261102_080459.csv` | - | First AirTag detection by service check |
| `tagalert_log_20261108_124708.csv` | - | Beep and detection, earlier build |
| `tagalert_log_20261108_141425.csv` | - | Beep 4 of 4 on own tags; stationary tags at Medium (before movement check) |
| `tagalert_log_20261108_180041.csv` | 1 | Movement check, stationary |
| `tagalert_log_20261108_184851.csv` | l | A2: None-level defect at 300 s |
| `tagalert_log_20261108_190309.csv` | m | A3, A4: stationary controls |
| `tagalert_log_20261108_193256.csv` | n | B1: walk, slow probe queue |
| `tagalert_log_20261108_194852.csv` | o | B2: walk, parked-tag false Medium |
| `tagalert_log_20261108_200330.csv` | r | B3: walk, passed-tag false Medium |
| `tagalert_log_20261108_201609.csv` | s | B4: walk, Low/Medium/High, no false alerts |
| `tagalert_log_20261108_203337.csv` | t | B5: walk, High at 2.5 min |
| `tagalert_log_20261108_210350.csv` | w | A5: stationary, distant-tag retry |
| `tagalert_log_20261108_211050.csv` | x | A6: stationary, distant tag heard rarely |
| `tagalert_log_20261108_212441.csv` | y | A7: owner-nearby beep finding |
| `tagalert_log_20261109_080815.csv` | a | A8: tags shown on confirmation; beep with owner away |
| `tagalert_log_20261109_080815_2.csv` | a | Export containing A8 and walk B6 |
| `tagalert_log_20261109_082940.csv` | b | B7: final walk, High at 2 min |
| `tagalert_log_20261109_084433_BAT1.csv` | b | BAT1: 47-minute battery run and stationary control |

Columns: `iso_time, event, tag_id, rssi, mfr_hex_first4, threat, persistence, detection_count, scan_interval_s, battery_pct, mode, note`. Recompute results with `python3 tools/analyze_log.py --totals logs/*.csv`.
