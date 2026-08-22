#!/usr/bin/env bash
# §10 spike runner. Compare output against EXPECTED.md.
set -uo pipefail
cd "$(dirname "$0")"

echo "=============================================================="
echo " 1. Build — runs SpikeBuildPlugin for ModuleA and App."
echo "    Watch for sandbox denials surfacing as build warnings/errors."
echo "=============================================================="
swift build 2>&1 | tee build.log

echo
echo "=============================================================="
echo " 2. Run App — prints both targets' probe reports (a/b/c)."
echo "=============================================================="
swift run App

echo
echo "=============================================================="
echo " 3. Command plugin — getSymbolGraph, available ONLY here."
echo "=============================================================="
swift package spike-symbolgraph 2>&1 || echo "(record the failure above — that is itself a finding)"

echo
echo "Done. Diff against EXPECTED.md and update SPIKE-FINDINGS.md in the repo root."
