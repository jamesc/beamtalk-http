# Copyright 2026 beamtalk_http authors
# SPDX-License-Identifier: Apache-2.0

# Standard Beamtalk project targets.
# See: https://beamtalk.dev/docs/tooling

# Build the project
build:
    beamtalk build

# Run the test suite
test:
    beamtalk test

# Run the test suite on the buccaneer backend (same tests, unchanged)
test-buccaneer:
    BEAMTALK_HTTP_BACKEND=buccaneer beamtalk test

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

# Full CI check (fmt + lint + build + test on both backends)
ci: fmt lint build test test-buccaneer

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
