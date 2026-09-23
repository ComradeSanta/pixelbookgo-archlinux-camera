#!/usr/bin/env bash
# install-desktop.sh — Install virtual camera desktop shortcuts to GNOME menu
# Run this on the HOST (outside the bwrap sandbox) after cloning / setting up
# the virtualcamera project.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLICATIONS_DIR="${HOME}/.local/share/applications"

info()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }

main() {
    echo ""
    info "Installing virtual camera desktop shortcuts…"
    echo ""

    mkdir -p "$APPLICATIONS_DIR"

    for desktop in vcam-toggle.desktop vcam-on.desktop vcam-off.desktop wemeetapp.desktop; do
        local src="${SCRIPT_DIR}/${desktop}"
        local dst="${APPLICATIONS_DIR}/${desktop}"

        if [ ! -f "$src" ]; then
            warn "Skipping $desktop — not found in $SCRIPT_DIR"
            continue
        fi

        # Remove old link/file if exists
        rm -f "$dst"

        # Symlink so updates in the project dir are reflected automatically
        if ln -s "$src" "$dst" 2>/dev/null; then
            ok "Installed: $desktop → $dst"
        else
            # Fallback: copy if symlink fails (e.g. across filesystems)
            cp "$src" "$dst"
            ok "Installed (copy): $desktop"
        fi
    done

    # Update GNOME desktop database
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
    fi

    echo ""
    ok "Installation complete!"
    info "You can now find in your GNOME menu:"
    info "  • Toggle Virtual Camera   (vcam-toggle.desktop — daily use)"
    info "  • Enable Virtual Camera   (vcam-on.desktop)"
    info "  • Disable Virtual Camera  (vcam-off.desktop)"
    info "  • 腾讯会议 WemeetApp       (wemeetapp.desktop — stock icon + camera shim)"
    echo ""
    info "Note: If shortcuts don't appear immediately, log out and back in."
}

main "$@"
