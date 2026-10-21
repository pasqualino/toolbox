#!/bin/zsh
# Lints the Swift sources with swift-format, using .swift-format. Exits non-zero on any finding.
# Usage: ./lint.sh          report only
#        ./lint.sh --fix    reformat in place first, then report what's left (naming, forEach and the like)
set -eu
cd "${0:A:h}"
paths=(Sources Package.swift)
if [[ "${1:-}" == "--fix" ]]; then
    swift format format --in-place --recursive --parallel $paths
fi
swift format lint --strict --recursive --parallel $paths && echo "Lint clean."
