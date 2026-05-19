_default:
    @just --list

# Build release .app; if displayVersion changed, prompt to install + restart Kooky
release:
    #!/usr/bin/env bash
    set -euo pipefail
    ./scripts/build-app.sh

    NEW="$(plutil -extract CFBundleShortVersionString raw -o - dist/Kooky.app/Contents/Info.plist)"
    OLD=""
    if [ -d /Applications/Kooky.app ]; then
        OLD="$(plutil -extract CFBundleShortVersionString raw -o - /Applications/Kooky.app/Contents/Info.plist 2>/dev/null || echo unknown)"
    fi

    if [ "$NEW" = "$OLD" ]; then
        echo ""
        echo "/Applications/Kooky.app already at v${NEW} — nothing to install."
        exit 0
    fi

    if [ -z "$OLD" ]; then
        PROMPT="Install Kooky v${NEW} into /Applications?"
    else
        PROMPT="Update Kooky in /Applications: v${OLD} → v${NEW}?"
    fi

    ANSWER=$(osascript \
        -e "display dialog \"${PROMPT}\" buttons {\"Cancel\", \"Install\"} default button \"Install\" with title \"kooky release\"" \
        -e "button returned of result" 2>/dev/null || echo "Cancel")

    if [ "$ANSWER" != "Install" ]; then
        echo "Install cancelled."
        exit 0
    fi

    SRC="$(pwd)/dist/Kooky.app"

    if pgrep -x Kooky >/dev/null; then
        # Detach so the script survives Kooky quitting (we may be running
        # inside Kooky's terminal — quit kills our shell otherwise).
        echo "Kooky is running — detaching install. Window will close, then v${NEW} will open."
        ( nohup bash -c "
            osascript -e 'tell application \"Kooky\" to quit' 2>/dev/null || true
            for i in \$(seq 1 60); do pgrep -x Kooky >/dev/null || break; sleep 0.1; done
            pkill -x Kooky 2>/dev/null || true
            sleep 0.3
            rm -rf /Applications/Kooky.app
            cp -R '${SRC}' /Applications/Kooky.app
            open /Applications/Kooky.app
        " >/tmp/kooky-install.log 2>&1 & )
    else
        rm -rf /Applications/Kooky.app
        cp -R "${SRC}" /Applications/Kooky.app
        open /Applications/Kooky.app
        echo "✓ Installed v${NEW}."
    fi
