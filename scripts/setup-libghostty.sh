#!/usr/bin/env bash
#
# Downloads and extracts a prebuilt GhosttyKit.xcframework into Vendor/.
# The v0.50.5 asset includes kooky-libghostty-issue53.patch. The BSDIFF40
# delta replaces its libghostty_zcu.o with the one rebuilt from the same
# sources plus kooky-libghostty-url-continuation.patch (Zig 0.16.0,
# native XCFramework, ReleaseFast, sentry off). All other objects come
# from the pinned asset.

set -euo pipefail

# Engine identity: <ghostty base SHA>-<kooky patch rev>. Bump the patch
# rev whenever the patched engine is rebuilt and republished.
GHOSTTY_SHA="88c3325dc9698d887da7e07ee0f9b79c53020be2-kooky53r1-links2"
EXPECTED_SHA256="fba19a549811a85323677660b35afa2e72cc81c58053669db94081e194c1e27e"
LIBRARY_SHA256="9d087ec23e1171a61075656229059b0808c3cffa3b560367ccf4c94a59be6330"
ARCHIVE_URL="https://github.com/iAmCorey/kooky/releases/download/v0.50.5/GhosttyKit.xcframework.tar.gz"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor"
FRAMEWORK_PATH="$VENDOR_DIR/GhosttyKit.xcframework"
STAMP_FILE="$VENDOR_DIR/.ghostty-sha"

if [[ -d "$FRAMEWORK_PATH" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$GHOSTTY_SHA" ]]; then
    echo "GhosttyKit.xcframework already at pinned engine ($GHOSTTY_SHA). Skipping."
    exit 0
fi

mkdir -p "$VENDOR_DIR"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kooky-ghosttykit.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE_PATH="$TMP_DIR/GhosttyKit.xcframework.tar.gz"

echo "Downloading GhosttyKit.xcframework ($GHOSTTY_SHA)..."
curl --fail --show-error --location \
    --connect-timeout 10 \
    --max-time 600 \
    --retry 5 \
    --retry-delay 5 \
    --retry-all-errors \
    -o "$ARCHIVE_PATH" \
    "$ARCHIVE_URL"

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "Checksum mismatch!" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

echo "Verified. Extracting..."
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar --no-same-owner -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

if [[ ! -d "$EXTRACT_DIR/GhosttyKit.xcframework" ]]; then
    echo "Archive did not contain GhosttyKit.xcframework at the expected path." >&2
    exit 1
fi

LIBRARY="$EXTRACT_DIR/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"
FIXED_LIBRARY="$TMP_DIR/libghostty-internal.a"
/usr/bin/bspatch "$LIBRARY" "$FIXED_LIBRARY" "$REPO_ROOT/scripts/kooky-libghostty-url-continuation.bsdiff"
printf '%s  %s\n' "$LIBRARY_SHA256" "$FIXED_LIBRARY" | shasum -a 256 -c -
mv "$FIXED_LIBRARY" "$LIBRARY"

rm -rf "$FRAMEWORK_PATH"
mv "$EXTRACT_DIR/GhosttyKit.xcframework" "$FRAMEWORK_PATH"

echo "$GHOSTTY_SHA" > "$STAMP_FILE"
echo "Installed: $FRAMEWORK_PATH"
