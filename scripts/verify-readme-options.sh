#!/usr/bin/env bash
set -euo pipefail

BINARY="${1:-dist/alien-findphone/findphone}"
README="${2:-README.md}"

if [ ! -x "$BINARY" ]; then
  echo "findphone binary not executable at: $BINARY" >&2
  exit 1
fi

help_output="$($BINARY --help 2>&1 || true)"

readme_options=$(
    awk '
        /^## Command-line options/ { inSection = 1; inCode = 0; next }
        inSection && /^```/ { inCode = 1 - inCode; next }
        inSection && /^## / { inSection = 0; next }
        inSection && inCode {
            for (i = 1; i <= split($0, tokens, /[[:space:]]+/); i++) {
                token = tokens[i]
                if (token ~ /^--[a-zA-Z][a-zA-Z0-9-]*/) {
                    gsub(/[,)]/, "", token)
                    print token
                }
            }
        }
    ' "$README" | sort -u
)
help_options=$(printf '%s\n' "$help_output" | grep -oE -- "--[a-zA-Z][a-zA-Z0-9-]*" | sort -u)

if [ -z "$readme_options" ]; then
  echo "No long options found in README" >&2
  exit 1
fi

if [ -z "$help_options" ]; then
  echo "No long options found in --help output" >&2
  exit 1
fi

missing=0

while IFS= read -r option; do
  if [ -z "$option" ]; then
    continue
  fi

  if ! printf '%s\n' "$help_options" | grep -qx -- "$option"; then
    echo "README documents option '$option' but --help does not list it" >&2
    missing=1
  fi

done <<< "$readme_options"

if [ $missing -ne 0 ]; then
  echo "Option coverage mismatch (README -> --help)." >&2
  exit 1
fi

# Ensure all public long options are present in README (excluding short aliases and defaults from hidden lines)
while IFS= read -r option; do
  if [ -z "$option" ]; then
    continue
  fi

  # Ignore internal test-only or non-documentable flags if they appear here.
  if [ "$option" = "--help" ]; then
    continue
  fi

  if ! printf '%s\n' "$readme_options" | grep -qx -- "$option"; then
    echo "--help documents option '$option' but README does not list it" >&2
    missing=1
  fi

done <<< "$help_options"

if [ $missing -ne 0 ]; then
  echo "Option coverage mismatch (--help -> README)." >&2
  exit 1
fi

echo "README and --help option sets are mutually covered."
