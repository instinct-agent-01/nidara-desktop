#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# fork-visual-probe.sh — FORK-ONLY (instinct-agent-01) computer-use probe.
# NOT for upstream. Runs at the end of phase_run in headless-smoke.sh, as the
# unprivileged `ci` user, with Hyprland + the shell already up and the
# computer-use gates enabled in ~/.config/nidara/ai.json.
#
# What it proves on the fork's CI:
#   1. PERCEPTION: nidara-a11y reads a third-party app's accessibility tree
#      over AT-SPI (allowComputerUse).
#   2. ACTION: nidara-click performs a REAL synthetic pointer click through
#      zwlr_virtual_pointer_v1 (allowComputerControl) whose effect is visible
#      in before/after grim captures and in the re-read a11y tree.
#
# Best-effort by contract: everything logs to /tmp/smoke/probe.log and every
# artifact lands in /tmp/smoke, which the finish() trap ships to the artifact
# bundle. A failure here reports "what is missing", it never fails the smoke.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
exec >>/tmp/smoke/probe.log 2>&1
set -x

REPO="${REPO:?}"
SMOKE=/tmp/smoke
export PATH="$SMOKE:$REPO/bin:$PATH"

# ── 1. AT-SPI bus ────────────────────────────────────────────────────────────
# There is no systemd --user in this container, so D-Bus activation of
# org.a11y.Bus cannot be relied on; run the launcher ourselves. It owns
# org.a11y.Bus on the session bus, spawns the a11y bus and the registry.
/usr/lib/at-spi-bus-launcher --launch-immediately &
sleep 2
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress || echo "PROBE-GAP: org.a11y.Bus.GetAddress failed"

# ── 2. Synthetic pointer backend (what install.sh compiles on a real install)
VP_XML=/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml
wayland-scanner client-header "$VP_XML" "$SMOKE/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$VP_XML" "$SMOKE/wlr-virtual-pointer-unstable-v1-protocol.c"
cc -O2 "$REPO/bin/nidara-input.c" "$SMOKE/wlr-virtual-pointer-unstable-v1-protocol.c" -I"$SMOKE" \
    $(pkg-config --cflags --libs wayland-client) -o "$SMOKE/nidara-input" \
    || echo "PROBE-GAP: nidara-input build failed"

# ── 3. A third-party GTK4 app to perceive and act on ─────────────────────────
GDK_BACKEND=wayland gtk3-widget-factory >"$SMOKE/widget-factory.log" 2>&1 &
APP=$!
for i in $(seq 1 20); do
    hyprctl clients -j | jq -e '.[] | select(.class=="gtk3-widget-factory")' >/dev/null 2>&1 && break
    sleep 1
done
hyprctl clients -j > "$SMOKE/clients.json"
# `hyprctl dispatch <classic string>` is a Lua syntax error under this
# repo's config parser; the dispatch argument must be a Lua expression.
hyprctl dispatch "hl.dsp.focus({ window = 'class:gtk3-widget-factory' })" || true
sleep 2
hyprctl activewindow -j > "$SMOKE/activewindow.json"

# ── 4. PERCEIVE: dump the a11y tree ──────────────────────────────────────────
GRIM_O=""
[ -s "$SMOKE/grim-output" ] && GRIM_O="$(cat "$SMOKE/grim-output")"
echo "grim output: ${GRIM_O:-<all>}"

gjs -m "$REPO/bin/nidara-a11y" gtk3-widget-factory > "$SMOKE/a11y-tree.json"
jq '{count, hint} + {first_nodes: [.nodes[0:8][] | {role, id, states, actions}]}' \
    "$SMOKE/a11y-tree.json" || head -c 2000 "$SMOKE/a11y-tree.json"
grim ${GRIM_O:+-o "$GRIM_O"} "$SMOKE/ai-before.png"

# ── 5. ACT: click a control; prove the change in tree + screenshot ───────────
TARGET="$(jq -r '[.nodes[] | select((.role=="toggle button" or .role=="check box" or .role=="push button") and (.id != null) and (.id != "") and (.visible==true))][0] | if . == null then "" else "\(.role)\t\(.id)" end' "$SMOKE/a11y-tree.json")"
ROLE="${TARGET%%$'\t'*}"; NAME="${TARGET#*$'\t'}"
echo "click target: role='$ROLE' name='$NAME'"
if [ -n "$NAME" ]; then
    gjs -m "$REPO/bin/nidara-click" app gtk3-widget-factory "$NAME" "$ROLE" > "$SMOKE/click-result.json"
    cat "$SMOKE/click-result.json"
    sleep 1
    gjs -m "$REPO/bin/nidara-a11y" gtk3-widget-factory > "$SMOKE/a11y-tree-after.json"
else
    echo "PROBE-GAP: no clickable node with an accessible name in the tree"
fi
grim ${GRIM_O:+-o "$GRIM_O"} "$SMOKE/ai-after.png"
kill "$APP" 2>/dev/null
echo "PROBE DONE"
