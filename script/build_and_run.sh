#!/usr/bin/env bash
# Run the isolated design app. Production and existing Dev builds stay open.
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
APP_NAME="Machogs Design"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/app/dist/$APP_NAME.app"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME is already open. Quit it, then run this again." >&2
    exit 3
fi
MACHOGS_CHANNEL=design "$ROOT_DIR/app/build.sh"
if [[ "$MODE" == --debug || "$MODE" == debug ]]; then
    exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
/usr/bin/open -n "$APP_BUNDLE" --args --design-preview
/usr/bin/open "machogs-design://now"
case "$MODE" in
    --logs|logs|--telemetry|telemetry)
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --verify|verify)
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
esac
