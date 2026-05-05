#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: CMUX_DEV_BUNDLE_ID_BASE=<bundle-prefix> [CMUX_DEVELOPMENT_TEAM=<team>] \
  ./scripts/reload-local-bundle.sh --tag <name> [reload.sh options]

Runs reload.sh with a local bundle id prefix without changing the Xcode project.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

TAG=""
for ((index = 1; index <= $#; index++)); do
  if [[ "${!index}" == "--tag" ]]; then
    next_index=$((index + 1))
    TAG="${!next_index:-}"
    break
  fi
done

if [[ -z "$TAG" ]]; then
  usage >&2
  exit 1
fi
if [[ -z "${CMUX_DEV_BUNDLE_ID_BASE:-}" ]]; then
  echo "error: CMUX_DEV_BUNDLE_ID_BASE is required" >&2
  usage >&2
  exit 1
fi

BUNDLE_ID="${CMUX_DEV_BUNDLE_ID_BASE}.$(sanitize_bundle "$TAG")"
XCCONFIG="$(mktemp "${TMPDIR:-/tmp}/cmux-local-bundle.XXXXXX.xcconfig")"
trap 'rm -f "$XCCONFIG"' EXIT

{
  printf 'PRODUCT_BUNDLE_IDENTIFIER = %s\n' "$BUNDLE_ID"
  if [[ -n "${CMUX_DEVELOPMENT_TEAM:-}" ]]; then
    printf 'DEVELOPMENT_TEAM = %s\n' "$CMUX_DEVELOPMENT_TEAM"
    printf 'CODE_SIGN_STYLE = Automatic\n'
  fi
} > "$XCCONFIG"

XCODE_XCCONFIG_FILE="$XCCONFIG" exec "$(dirname "$0")/reload.sh" --bundle-id "$BUNDLE_ID" "$@"
