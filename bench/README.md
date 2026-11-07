# Client load bench: `just bench` and `just bench-smoke`

BT-4546: throughput and latency of `HTTPClient` (and Mint H2 directly)
under concurrent load — the dimension the sequential
`test/httpclient_bench_test.bt` smoke cannot see. Modelled on
beamtalk-buccaneer's `bench/` (interleaved rows × rounds, warmup,
`RESULTS.md`, non-blocking CI smoke), adapted: the driver is Beamtalk
(`bench/driver`, run via `beamtalk run BenchMain main:`), workers are
plain actors driving the public client API, and reports render from the
workers' raw samples files.

```bash
just bench                                # every row, 3 rounds x 5 s
just bench --rounds 1 --duration 1000 --warmup 300 --rows oneshot-get-c1,persistent-get-c1
just bench --impls mint,gun               # plus gun baseline rows
just bench --only h2                      # substring filter on row names
just bench-smoke                          # 1 round x 1 s on the smoke rows (CI)
```

Neither is part of `just test`; CI runs `bench-smoke` non-blocking.
Needs `beamtalk` and python3 on `PATH`. Gun rows build a scratch
worktree of the pre-mint tree at `GUN_REV` (default `fc6ac6c`; network
on the first run for the gun Hex dependency); a failed gun build skips
gun rows with a message. Baseline numbers live in [RESULTS.md](RESULTS.md).

`bench/run.sh` builds everything, then runs one row × round per driver
invocation: `bench/driver` starts a fresh local `HTTPServer`
(Buccaneer backend, ephemeral port) per measurement, spawns one
`BenchWorker` actor per connection, and writes raw per-request latencies
to `_build/bench/raw-<stamp>/<row>.<impl>.r<round>/`. `bench/report.py`
renders `_build/bench/REPORT.md` (per-round figures plus per-row medians
with min-max spread and gun/mint ratios).

## Rows

| Row | Load |
|---|---|
| `oneshot-get-c1`, `oneshot-get-c5` | fresh connection per `GET /` (connect cost) |
| `persistent-get-c1` ... `persistent-get-c50` | one `HTTPClient` actor per worker, keep-alive reuse |
| `ppost-echo-64k-c10` | `POST /echo`, 64 KiB body, on reused connections |
| `pbig-1mib-c10` | `GET /big` (1 MiB body), sustained download for BT-4541 |
| `h2-multi-c5s10` | Mint H2 directly (HTTPClient has no h2c path): 5 conns × 10 interleaved streams |

## Port budget

One-shot rows churn a client ephemeral port per connection, and the
client closes first, so TIME_WAIT sits client-side: stock systems have
~16k ephemeral ports with tens of seconds of TIME_WAIT, sustaining only
a few hundred fresh connections per second on loopback. Past that the
kernel answers `#eaddrnotavail` — an environment limit, not a client
result (both backends hit the identical wall; the first full run proved
it with 24k such errors). So one-shot workers pace themselves (2 ms
between requests, outside the measured region), one-shot rows stay
short (2 s) and few, `run.sh` sleeps 2 s between measurements, and
throughput-at-concurrency lives on the persistent rows. There are no
uncapped-churn rows on purpose: on loopback they would measure the OS
port budget, not the client.

Every round measures every row once per impl, back to back, rotating
which row goes first; each measurement starts a fresh server. The
report gives every round, the medians, each side's spread (min-max over
the rounds) and gun/mint ratios where both ran.

There are no TLS rows: `HTTPServer` has no TLS option, so neither
backend can serve them locally.

## Gun rows

`--impls mint,gun` additionally measures the pre-mint tree at `GUN_REV`
for release-over-release context (each impl runs its own tree's server,
so gun rows compare stacks, not clients). Gun rows are opt-in, not
default, for two reasons: the gun stack is deleted, so its numbers are
context only; and the old stack churns connections an order of
magnitude harder under this harness (a single persistent-c1 run left
~13k TIME_WAIT behind), which saturates the loopback port table and
invalidates the mint rows sharing the run. If you run gun rows, run
them as a separate invocation on a drained table and read them
accordingly. The gun-vs-mint parity gate for the BT-4530 merge was met
earlier by the sequential smoke, not by this harness.

## Caveats

- Clients and server share one VM (and its schedulers); buccaneer's
  harness isolates them in peer VMs. Rows compare backends under
  identical conditions, so ratios hold — read absolutes accordingly.
- The machine is usually shared. Compare within the rounds' spread.
- Program arguments arrive as Binaries, not Strings (they never `=:=`
  or hash alike): the driver normalizes to text once in `parseArgs:`.
