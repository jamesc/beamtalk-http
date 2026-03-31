# Standard Beamtalk project targets.
# See: https://beamtalk.dev/docs/tooling

# Build the project
build:
    beamtalk build

# Run the test suite
test:
    beamtalk test

# Check formatting
fmt:
    beamtalk fmt-check

# Format in place
fmt-fix:
    beamtalk fmt

# Full CI check (fmt + build + test)
ci: fmt build test

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
