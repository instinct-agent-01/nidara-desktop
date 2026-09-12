#!/usr/bin/env -S gjs -m
// probe-app.js — FORK-ONLY CI fixture (instinct-agent-01). A minimal GTK4
// window with named controls, standing in for a third-party app in the
// computer-use probe. Icon-free ON PURPOSE: every SVG icon load in this
// container goes through glycin's bwrap-sandboxed loader, which dies here,
// and takes the whole app with it (both stock GTK widget factories crash).
import Gtk from "gi://Gtk?version=4.0"

const app = new Gtk.Application({ application_id: "org.nidara.Probe" })
app.connect("activate", () => {
    const win = new Gtk.ApplicationWindow({ application: app, title: "Nidara Probe" })
    const box = new Gtk.Box({
        orientation: Gtk.Orientation.VERTICAL, spacing: 12,
        margin_top: 24, margin_bottom: 24, margin_start: 24, margin_end: 24,
    })
    const label = new Gtk.Label({ label: "Nidara computer-use probe" })
    const toggle = new Gtk.ToggleButton({ label: "Probe toggle" })
    const button = new Gtk.Button({ label: "Probe button" })
    const counter = new Gtk.Label({ label: "Clicks: 0" })
    let n = 0
    button.connect("clicked", () => { n += 1; counter.set_label(`Clicks: ${n}`) })
    box.append(label); box.append(toggle); box.append(button); box.append(counter)
    win.set_child(box)
    win.set_default_size(480, 320)
    win.present()
})
app.run([])
