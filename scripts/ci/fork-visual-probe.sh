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
# The probe app is a purpose-built GJS/GTK4 window (probe-app.js): BOTH stock
# GTK demo apps crash in this container — every SVG icon load goes through
# glycin's bwrap-sandboxed loader, which exits early here (no user namespaces
# for the sandbox). An icon-free app sidesteps that entirely.
#
# Best-effort by contract: logs to /tmp/smoke/probe.log, artifacts in
# /tmp/smoke (the finish() trap ships them to the artifact bundle). A failure
# here reports "what is missing"; it never fails the smoke.
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
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus     --method org.a11y.Bus.GetAddress || echo "PROBE-GAP: org.a11y.Bus.GetAddress failed"

# ── 2. Synthetic pointer backend (what install.sh compiles on a real install)
VP_XML=/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml
wayland-scanner client-header "$VP_XML" "$SMOKE/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$VP_XML" "$SMOKE/wlr-virtual-pointer-unstable-v1-protocol.c"
cc -O2 "$REPO/bin/nidara-input.c" "$SMOKE/wlr-virtual-pointer-unstable-v1-protocol.c" -I"$SMOKE"     $(pkg-config --cflags --libs wayland-client) -o "$SMOKE/nidara-input"     || echo "PROBE-GAP: nidara-input build failed"

# ── 3. The third-party probe app ─────────────────────────────────────────────
GDK_BACKEND=wayland gjs -m "$REPO/scripts/ci/probe-app.js" >"$SMOKE/probe-app.log" 2>&1 &
APP=$!
for i in $(seq 1 20); do
    hyprctl clients -j | jq -e '.[] | select(.class=="org.nidara.Probe")' >/dev/null 2>&1 && break
    sleep 1
done
hyprctl clients -j > "$SMOKE/clients.json"
# `hyprctl dispatch <classic string>` is a Lua syntax error under this repo's
# config parser; the dispatch argument must be a Lua expression.
hyprctl dispatch "hl.dsp.focus({ window = 'class:org.nidara.Probe' })" || true
sleep 2
hyprctl activewindow -j > "$SMOKE/activewindow.json"

GRIM_O=""
[ -s "$SMOKE/grim-output" ] && GRIM_O="$(cat "$SMOKE/grim-output")"
echo "grim output: ${GRIM_O:-<all>}"

# ── 4. PERCEIVE: dump the a11y tree ──────────────────────────────────────────
gjs -m "$REPO/bin/nidara-a11y" probe > "$SMOKE/a11y-tree.json"
jq '{count, hint} + {first_nodes: [.nodes[0:10][] | {role, id, states, actions}]}'     "$SMOKE/a11y-tree.json" || head -c 2000 "$SMOKE/a11y-tree.json"
grim ${GRIM_O:+-o "$GRIM_O"} "$SMOKE/ai-before.png"

# ── 5. ACT: three layers, each verified against a fresh a11y dump ───────────
#   a. nidara-click (gated wrapper: focus check, AT-SPI node resolve, inject)
#   b. nidara-input DIRECT (raw virtual-pointer click on the button's centre)
#   c. nidara-act (AT-SPI do_action — the semantic path, same gate)
EXT="$(hyprctl monitors -j | jq -r '.[0] | "\(.width/(.scale)) \(.height/(.scale))"' | awk '{print $1" "$2}')"
EW="${EXT%% *}"; EH="${EXT##* }"
echo "output extent (logical): ${EW}x${EH}"

dump() { gjs -m "$REPO/bin/nidara-a11y" probe > "$1"; }

state_of() { jq -r '[.nodes[] | select(.id=="Probe toggle" and .role=="toggle button") | .states[]] | join(",")' "$1"; }
clicks_of() { jq -r '[.nodes[] | select(.role=="label") | .id // empty] | map(select(startswith("Clicks:"))) | .[0] // "?"' "$1"; }

# (a) wrapped click on the toggle
dump "$SMOKE/a11y-tree.json"
grim ${GRIM_O:+-o "$GRIM_O"} "$SMOKE/ai-before.png"
gjs -m "$REPO/bin/nidara-click" app probe "Probe toggle" "toggle button" > "$SMOKE/click-result.json"
cat "$SMOKE/click-result.json"
sleep 1
dump "$SMOKE/a11y-after-click.json"
echo "toggle states after nidara-click: $(state_of "$SMOKE/a11y-after-click.json")"

# (b) direct injector click on the button (counter text is unambiguous proof)
WAT="$(hyprctl clients -j | jq -r '.[] | select(.class=="org.nidara.Probe") | .at | "\(.[0]) \(.[1])"')"
WX="${WAT%% *}"; WY="${WAT##* }"
read BX BY BW BH <<<"$(jq -r '.nodes[] | select(.id=="Probe button" and .role=="button") | .bounds | "\(.x) \(.y) \(.w) \(.h)"' "$SMOKE/a11y-after-click.json")"
CX=$(( WX + BX + BW/2 )); CY=$(( WY + BY + BH/2 ))
echo "direct click at $CX,$CY (window at $WX,$WY)"
"$SMOKE/nidara-input" click "$CX" "$CY" "$EW" "$EH" || echo "PROBE-GAP: direct nidara-input click failed"
sleep 1
dump "$SMOKE/a11y-after-direct.json"
echo "counter after direct click: $(clicks_of "$SMOKE/a11y-after-direct.json")"

# (c) AT-SPI do_action on the toggle
gjs -m "$REPO/bin/nidara-act" probe "Probe toggle" click "toggle button" > "$SMOKE/act-result.json"
cat "$SMOKE/act-result.json"
sleep 1
dump "$SMOKE/a11y-after-act.json"
echo "toggle states after nidara-act: $(state_of "$SMOKE/a11y-after-act.json")"

# (d) wev diagnostic: does the compositor deliver virtual-pointer BUTTON
# events at all in this environment? wev logs every event it receives.
GDK_BACKEND=wayland stdbuf -oL wev > "$SMOKE/wev.log" 2>&1 &
WEV=$!
for i in $(seq 1 15); do
    hyprctl clients -j | jq -e '.[] | select(.class=="wev" or .initialClass=="wev")' >/dev/null 2>&1 && break
    sleep 1
done
hyprctl dispatch "hl.dsp.focus({ window = 'class:wev' })" || true
sleep 1
read WVX WVY <<<"$(hyprctl clients -j | jq -r '.[] | select(.class=="wev" or .initialClass=="wev") | .at | "\(.[0]) \(.[1])"' 2>/dev/null)"
read WVW WVH <<<"$(hyprctl clients -j | jq -r '.[] | select(.class=="wev" or .initialClass=="wev") | .size | "\(.[0]) \(.[1])"' 2>/dev/null)"
if [ -n "${WVX:-}" ] && [ -n "${WVW:-}" ]; then
    MCX=$(( WVX + WVW/2 )); MCY=$(( WVY + WVH/2 ))
    echo "wev at $WVX,$WVY size ${WVW}x${WVH} - clicking $MCX,$MCY"
    "$SMOKE/nidara-input" move "$MCX" "$MCY" "$EW" "$EH"
    sleep 1
    "$SMOKE/nidara-input" click "$MCX" "$MCY" "$EW" "$EH"
    sleep 1
else
    echo "PROBE-GAP: wev window not found"
fi
kill "$WEV" 2>/dev/null
echo "── wev events received (pointer) ──"
grep -E 'pointer.*(enter|motion|button)' "$SMOKE/wev.log" | tail -20 || tail -20 "$SMOKE/wev.log"

echo "── probe-app event log ──"
cat "$SMOKE/probe-app.log" || true

grim ${GRIM_O:+-o "$GRIM_O"} "$SMOKE/ai-after.png"
kill "$APP" 2>/dev/null
echo "PROBE DONE"
