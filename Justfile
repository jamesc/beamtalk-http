# Copyright 2026 beamtalk_http authors
# SPDX-License-Identifier: Apache-2.0

# Standard Beamtalk project targets.
# See: https://beamtalk.dev/docs/tooling

# Build the project
build:
    beamtalk build

# Run the test suite
test:
    beamtalk test --warnings-as-errors

# Check formatting
fmt:
    beamtalk fmt-check

# Format in place
fmt-fix:
    beamtalk fmt

# Lint source files
lint:
    beamtalk lint

# Remove build artifacts
clean:
    rm -rf _build

# Full CI check (fmt + lint + build + test)
ci: fmt lint build test

# Client load bench (BT-4546): every row, interleaved rounds (bench/README.md)
bench *ARGS:
    bench/run.sh {{ARGS}}

# One short bench round on the smoke rows, as CI runs it (non-blocking)
bench-smoke:
    bench/run.sh --impls mint --rows oneshot-get-c1,persistent-get-c1 --rounds 1 --duration 1000 --warmup 300

# Tag a release from beamtalk.toml version
release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(grep '^version' beamtalk.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    git tag "v${version}"
    echo "Tagged v${version}"

# Push release tags to origin
publish:
    git push origin --tags

# Option shapes reject a wrong option type at a call site (BT-4736)
check-shapes:
    #!/usr/bin/env bash
    set -uo pipefail
    out=$(beamtalk lint test_negative/wrong_timeout.bt 2>&1); status=$?
    echo "$out"
    if [ $status -eq 0 ] || ! echo "$out" | grep -qi "timeout"; then
        echo "expected a diagnostic for #timeout => \"5s\"" >&2
        exit 1
    fi
