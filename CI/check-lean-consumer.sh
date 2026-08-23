#!/usr/bin/env bash
# Fails if a lean consumer resolves any dependency the traits should prune.
set -euo pipefail
cd "$(dirname "$0")/lean-consumer"
rm -f Package.resolved
swift build
forbidden=(hummingbird jwt-kit async-http-client swift-certificates swift-nio-ssl)
status=0
for pkg in "${forbidden[@]}"; do
  if grep -q "\"identity\" : \"$pkg\"" Package.resolved; then
    echo "::error::lean consumer resolved '$pkg' — trait gating has regressed"
    status=1
  fi
done
echo "lean consumer resolved $(grep -c '"identity"' Package.resolved) packages"
[ $status -eq 0 ] && echo "no gated dependency leaked"
exit $status
