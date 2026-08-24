#!/usr/bin/env bash
# Fails if a lean consumer resolves any dependency the traits should prune.
set -euo pipefail
cd "$(dirname "$0")/lean-consumer"
rm -f Package.resolved
# `swift build` alone will not rewrite Package.resolved when .build already
# holds resolution state, which would leave nothing for the check to read.
swift package resolve
swift build
# A missing Package.resolved means the build never resolved anything, and a
# check that cannot tell "clean" from "did not run" is worse than no check.
if [ ! -f Package.resolved ]; then
  echo "::error::no Package.resolved after building the lean consumer"
  exit 1
fi

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
