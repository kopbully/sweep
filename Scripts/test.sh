#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/regression
sources=(Sources/Sweep/*.swift)
sources=(${sources:#Sources/Sweep/SweepApp.swift})
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 \
    -module-cache-path .build/clang-cache \
    "${sources[@]}" Tests/Regression.swift -o .build/regression/checks
.build/regression/checks
