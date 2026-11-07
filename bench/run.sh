#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Client load bench (BT-4546), modelled on beamtalk-buccaneer's bench/:
# interleaved rows x rounds against a fresh local server per measurement,
# raw samples to _build/bench/, REPORT.md rendered at the end.
#
#   bench/run.sh                                           # every row, 3 rounds x 5 s
#   bench/run.sh --rounds 1 --duration 1000 --warmup 300 \
#     --rows oneshot-get-c1,persistent-get-c1              # smoke shape
#   bench/run.sh --impls mint,gun                         # plus gun baseline rows
#                                                     (opt-in: see README "Gun rows")
#   bench/run.sh --only h2                                # substring filter on row names
#
# Neither bench nor bench-smoke is part of `just test`; CI runs
# bench-smoke as a non-blocking step. Needs `beamtalk` and python3 on
# PATH. Gun rows build a scratch worktree at GUN_REV (network on the
# first run for the gun Hex dependency); a failed gun build skips gun
# rows with a message instead of failing the run.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
GUN_REV="${BENCH_GUN_REV:-fc6ac6c}"

rounds=3
duration=5000
warmup=1000
rows_sel=""
only=""
impls="mint"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds) rounds="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --warmup) warmup="$2"; shift 2 ;;
    --rows) rows_sel="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --impls) impls="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# name|mode|workers|streams|duration-ms|impls. One-shot rows stay short:
# loopback churn burns a client ephemeral port per connection and stock
# systems only have ~16k (see README "Port budget").
ALL_ROWS=(
  "oneshot-get-c1|oneshot|1|0|2000|mint,gun"
  "oneshot-get-c5|oneshot|5|0|2000|mint,gun"
  "persistent-get-c1|persistent|1|0|5000|mint,gun"
  "persistent-get-c10|persistent|10|0|5000|mint,gun"
  "persistent-get-c50|persistent|50|0|5000|mint,gun"
  "ppost-echo-64k-c10|ppost|10|0|5000|mint,gun"
  "pbig-1mib-c10|pbig|10|0|5000|mint,gun"
  "h2-multi-c5s10|h2|5|10|5000|mint"
)

ROWS=()
if [[ -n "$rows_sel" ]]; then
  IFS=',' read -ra WANT <<< "$rows_sel"
  for r in "${ALL_ROWS[@]}"; do
    name="${r%%|*}"
    for w in "${WANT[@]}"; do
      [[ "$name" == "$w" ]] && ROWS+=("$r")
    done
  done
else
  for r in "${ALL_ROWS[@]}"; do
    name="${r%%|*}"
    [[ -z "$only" || "$name" == *"$only"* ]] && ROWS+=("$r")
  done
fi
[[ "${#ROWS[@]}" -gt 0 ]] || { echo "no rows selected" >&2; exit 2; }

echo "== building http =="
(cd "$root" && beamtalk build >/dev/null)
echo "== building bench driver =="
(cd "$root/bench/driver" && beamtalk build >/dev/null)

raw="$root/_build/bench/raw-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$raw"

setup_gun() {
  local gunwb="$root/_build/bench/beamtalk-http-gun"
  local have=""
  if [[ -e "$gunwb/.git" && -f "$gunwb/beamtalk.toml" ]]; then
    have="$(git -C "$gunwb" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ "$have" != "$GUN_REV"* ]]; then
    echo "== setting up gun worktree at $GUN_REV =="
    git -C "$root" worktree remove --force "$gunwb" >/dev/null 2>&1 || true
    rm -rf "$gunwb"
    git -C "$root" worktree add --detach "$gunwb" "$GUN_REV" >/dev/null 2>&1
  fi
  rm -rf "$gunwb/bench"
  mkdir -p "$gunwb/bench"
  cp -r "$root/bench/driver" "$gunwb/bench/driver"
  # The gun tree predates the mint dependency: the driver needs it.
  grep -q '^mint = ' "$gunwb/bench/driver/beamtalk.toml" \
    || echo 'mint = "0.1.0"' >> "$gunwb/bench/driver/beamtalk.toml"
  (cd "$gunwb" && beamtalk build >/dev/null 2>&1) \
    && (cd "$gunwb/bench/driver" && beamtalk build >/dev/null 2>&1)
}

GUN_OK=0
IFS=',' read -ra IMPLS <<< "$impls"
for impl in "${IMPLS[@]}"; do
  if [[ "$impl" == "gun" ]]; then
    if setup_gun; then
      GUN_OK=1
    else
      echo "!! gun worktree build failed; skipping gun rows" >&2
    fi
  elif [[ "$impl" != "mint" ]]; then
    echo "unknown impl: $impl (want mint[,gun])" >&2; exit 2
  fi
done

fails=()
round=0
while (( round < rounds )); do
  round=$(( round + 1 ))
  # Rotate row order per round: interleaved backends/rows like buccaneer.
  n="${#ROWS[@]}"
  off=$(( (round - 1) % n ))
  ORDERED=("${ROWS[@]:off}" "${ROWS[@]:0:off}")
  first=1
  for r in "${ORDERED[@]}"; do
    IFS='|' read -r name mode workers streams rowdur rowimpls <<< "$r"
    for impl in "${IMPLS[@]}"; do
      [[ ",$rowimpls," == *",$impl,"* ]] || continue
      [[ "$impl" == "gun" && "$GUN_OK" != "1" ]] && continue
      if [[ "$impl" == "gun" ]]; then
        driverdir="$root/_build/bench/beamtalk-http-gun/bench/driver"
      else
        driverdir="$root/bench/driver"
      fi
      # Let TIME_WAIT drain between measurements (see README "Port budget").
      [[ "$first" == "1" ]] && first=0 || sleep 2
      out="$raw/$name.$impl.r$round"
      mkdir -p "$out"
      echo "-- $name [$impl] round $round/$rounds"
      # shellcheck disable=SC2086
      if (cd "$driverdir" && beamtalk run BenchMain main: -- \
          --row "$name" --mode "$mode" --workers "$workers" \
          --duration-ms "$rowdur" --warmup-ms "$warmup" \
          --out "$out" --impl "$impl" --round "$round" \
          --streams "$streams"); then
        :
      else
        echo "!! row failed: $name [$impl] round $round" >&2
        fails+=("$name [$impl] round $round")
      fi
    done
  done
done

echo "== report =="
python3 "$root/bench/report.py" "$raw" "$root/_build/bench/REPORT.md"

if (( ${#fails[@]} > 0 )); then
  echo "FAILED ROWS:" >&2
  printf '  %s\n' "${fails[@]}" >&2
  exit 1
fi
echo "all rows ok"
