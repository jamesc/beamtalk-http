# Client load bench baseline

BT-4546 baseline, recorded by `just bench` (3 rounds x 5 s, loopback, this machine). See [README.md](README.md) for rows, caveats (single VM, port budget) and the gate rule.

# Client load bench report

Recorded 2026-11-07 19:39 UTC by bench/run.sh (BT-4546).
http rev 2d269ce; beamtalk beamtalk 0.4.0.
Fresh local server per measurement; loopback; medians over rounds.

| row | impl | rounds | req/s (spread) | p50 ms | p99 ms (spread) | gun/mint req/s |
|---|---|---|---|---|---|---|
| h2-multi-c5s10 | mint | 3 | 17737 (17607-17744) | 1.00 | 3.00 (3.00-3.00) |  |
| oneshot-get-c1 | mint | 3 | 262 (260-262) | 0.00 | 1.00 (1.00-1.00) |  |
| oneshot-get-c5 | mint | 3 | 1632 (1608-1656) | 0.00 | 0.00 (0.00-0.00) |  |
| pbig-1mib-c10 | mint | 3 | 3760 (3752-3795) | 2.00 | 3.00 (3.00-3.00) |  |
| persistent-get-c1 | mint | 3 | 6066 (6018-6095) | 0.00 | 1.00 (1.00-1.00) |  |
| persistent-get-c10 | mint | 3 | 18817 (18602-18984) | 0.00 | 1.00 (1.00-1.00) |  |
| persistent-get-c50 | mint | 3 | 19208 (19176-19238) | 0.00 | 1.00 (1.00-1.00) |  |
| ppost-echo-64k-c10 | mint | 3 | 14818 (14758-14880) | 0.00 | 1.00 (1.00-1.00) |  |

## Per-round figures

| row | impl | round | n | req/s | min | p50 | p99 | max |
|---|---|---|---|---|---|---|---|---|
| h2-multi-c5s10 | mint | 1 | 88686 | 17737 | 0.00 | 1.00 | 3.00 | 45.00 |
| h2-multi-c5s10 | mint | 2 | 88034 | 17607 | 0.00 | 1.00 | 3.00 | 205.00 |
| h2-multi-c5s10 | mint | 3 | 88720 | 17744 | 0.00 | 1.00 | 3.00 | 199.00 |
| oneshot-get-c1 | mint | 1 | 525 | 262 | 0.00 | 0.00 | 1.00 | 1.00 |
| oneshot-get-c1 | mint | 2 | 523 | 262 | 0.00 | 0.00 | 1.00 | 1.00 |
| oneshot-get-c1 | mint | 3 | 520 | 260 | 0.00 | 0.00 | 1.00 | 1.00 |
| oneshot-get-c5 | mint | 1 | 3215 | 1608 | 0.00 | 0.00 | 0.00 | 9.00 |
| oneshot-get-c5 | mint | 2 | 3264 | 1632 | 0.00 | 0.00 | 0.00 | 6.00 |
| oneshot-get-c5 | mint | 3 | 3311 | 1656 | 0.00 | 0.00 | 0.00 | 5.00 |
| pbig-1mib-c10 | mint | 1 | 18975 | 3795 | 1.00 | 2.00 | 3.00 | 4.00 |
| pbig-1mib-c10 | mint | 2 | 18800 | 3760 | 1.00 | 2.00 | 3.00 | 4.00 |
| pbig-1mib-c10 | mint | 3 | 18761 | 3752 | 1.00 | 2.00 | 3.00 | 4.00 |
| persistent-get-c1 | mint | 1 | 30089 | 6018 | 0.00 | 0.00 | 1.00 | 18.00 |
| persistent-get-c1 | mint | 2 | 30328 | 6066 | 0.00 | 0.00 | 1.00 | 16.00 |
| persistent-get-c1 | mint | 3 | 30477 | 6095 | 0.00 | 0.00 | 1.00 | 4.00 |
| persistent-get-c10 | mint | 1 | 94087 | 18817 | 0.00 | 0.00 | 1.00 | 16.00 |
| persistent-get-c10 | mint | 2 | 93009 | 18602 | 0.00 | 0.00 | 1.00 | 14.00 |
| persistent-get-c10 | mint | 3 | 94921 | 18984 | 0.00 | 0.00 | 1.00 | 2.00 |
| persistent-get-c50 | mint | 1 | 96192 | 19238 | 0.00 | 0.00 | 1.00 | 13.00 |
| persistent-get-c50 | mint | 2 | 95879 | 19176 | 0.00 | 0.00 | 1.00 | 12.00 |
| persistent-get-c50 | mint | 3 | 96039 | 19208 | 0.00 | 0.00 | 1.00 | 2.00 |
| ppost-echo-64k-c10 | mint | 1 | 74401 | 14880 | 0.00 | 0.00 | 1.00 | 1.00 |
| ppost-echo-64k-c10 | mint | 2 | 73789 | 14758 | 0.00 | 0.00 | 1.00 | 1.00 |
| ppost-echo-64k-c10 | mint | 3 | 74089 | 14818 | 0.00 | 0.00 | 1.00 | 1.00 |
