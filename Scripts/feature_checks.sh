#!/bin/zsh
# 功能/删除链路验收：只操作自建夹具，见 Tests/FeatureChecks.swift
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/feature
rm -f .build/feature/checks
sources=(Sources/Sweep/*.swift)
sources=(${sources:#Sources/Sweep/SweepApp.swift})
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 \
    -module-cache-path .build/clang-cache \
    "${sources[@]}" Tests/FeatureChecks.swift -o .build/feature/checks 2>/dev/null || {
    echo "compile failed"; exit 1; }
.build/feature/checks
