#!/usr/bin/env python3
"""Minimal reproduction: a GTK3 + gtk-layer-shell window that is mapped but never drawn.

Observed on Debian with GTK 3.24.52, gtk-layer-shell 0.10.1 and libwayland 1.26,
under labwc 0.20.2 (nested and headless) and sway 1.12 (headless). The layer surface is
created, configured and acknowledged, but GTK never calls the draw handler and no
buffer is attached. Remove the three GtkLayerShell lines and the same window draws.

Run inside a Wayland session that supports wlr-layer-shell:

    GDK_BACKEND=wayland python3 wayland-layer-shell-repro.py

Expected: a red 300x70 bar at the bottom edge, and "draw called" on stdout.
Actual:   nothing is drawn, and "draws: 0" repeats.

Add WAYLAND_DEBUG=client to see the missing wl_surface.attach after ack_configure.
"""
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, GtkLayerShell, GLib

print("GTK %d.%d.%d, layer-shell supported: %s" % (
    Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version(),
    GtkLayerShell.is_supported()))

window = Gtk.Window()
GtkLayerShell.init_for_window(window)
GtkLayerShell.set_layer(window, GtkLayerShell.Layer.TOP)
GtkLayerShell.set_anchor(window, GtkLayerShell.Edge.BOTTOM, True)
window.set_default_size(300, 70)

draws = [0]

def on_draw(widget, cr):
    draws[0] += 1
    print("draw called", draws[0], widget.get_allocated_width(), widget.get_allocated_height())
    cr.set_source_rgba(0.9, 0.2, 0.2, 1)
    cr.paint()
    return False

window.connect("draw", on_draw)
window.show_all()

def report():
    print("mapped:", window.get_mapped(), "draws:", draws[0])
    return True

GLib.timeout_add_seconds(2, report)
GLib.timeout_add_seconds(10, Gtk.main_quit)
Gtk.main()
