#!/usr/bin/env bash
set -euo pipefail

# Uploads debug symbols to Sentry so crash reports arrive symbolicated.
#
# With no argument it covers the app and every bundled plugin, which come out of
# the same xcodebuild invocation and share one products directory. The plugin
# release workflow passes its own per-arch directory instead.
#
# Requires SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT in the environment.

PRODUCTS_DIR="${1:-build/DerivedData/Build/Products/Release}"

if [[ ! -d "$PRODUCTS_DIR" ]]; then
    echo "❌ FATAL: $PRODUCTS_DIR not found. Run the release build first."
    exit 1
fi

DSYM_COUNT=$(find "$PRODUCTS_DIR" -maxdepth 1 -name "*.dSYM" | wc -l | tr -d ' ')
if [[ "$DSYM_COUNT" -eq 0 ]]; then
    echo "❌ FATAL: no dSYM bundles in $PRODUCTS_DIR. Check DEBUG_INFORMATION_FORMAT for Release."
    exit 1
fi
echo "📦 Found $DSYM_COUNT dSYM bundles"

if ! command -v sentry-cli >/dev/null 2>&1; then
    brew install getsentry/tools/sentry-cli
fi

# --include-sources stays off: it would upload this repository's source to Sentry.
sentry-cli debug-files upload --include-sources=false "$PRODUCTS_DIR"

echo "✅ Uploaded debug symbols to Sentry"
