#ifndef DOKKU_TOPLEVEL_TRACKER_H
#define DOKKU_TOPLEVEL_TRACKER_H

#include <glib.h>
#include <stdint.h>

/* Lists the windows a Wayland compositor has open, through the
 * wlr-foreign-toplevel-management protocol (sway, labwc, Wayfire, Hyprland and
 * others provide it). It uses a connection of its own, so GDK's is untouched, and
 * is driven by the GLib main loop. */

typedef struct _DokkuToplevelTracker DokkuToplevelTracker;
typedef struct _DokkuToplevel DokkuToplevel;

typedef enum {
    DOKKU_TOPLEVEL_ADDED,     /* the window is known and its first state has arrived */
    DOKKU_TOPLEVEL_CHANGED,   /* title, app id, state or output changed */
    DOKKU_TOPLEVEL_CLOSED     /* last call for this window: it is freed afterwards */
} DokkuToplevelEvent;

enum {
    DOKKU_TOPLEVEL_STATE_MAXIMIZED  = 1 << 0,
    DOKKU_TOPLEVEL_STATE_MINIMIZED  = 1 << 1,
    DOKKU_TOPLEVEL_STATE_ACTIVATED  = 1 << 2,
    DOKKU_TOPLEVEL_STATE_FULLSCREEN = 1 << 3
};

typedef void (*DokkuToplevelFunc)(DokkuToplevelEvent event, DokkuToplevel *toplevel, void *data);

/* NULL when there is no Wayland connection or the compositor lacks the protocol */
DokkuToplevelTracker *dokku_toplevel_tracker_new(DokkuToplevelFunc func, void *data);
void dokku_toplevel_tracker_free(DokkuToplevelTracker *tracker);

const char *dokku_toplevel_get_title(DokkuToplevel *toplevel);
const char *dokku_toplevel_get_app_id(DokkuToplevel *toplevel);
uint32_t dokku_toplevel_get_state(DokkuToplevel *toplevel);
/* Whether the window is on the output whose top-left corner is at (x, y) in the layout */
gboolean dokku_toplevel_is_on_output_at(DokkuToplevel *toplevel, int x, int y);

void dokku_toplevel_activate(DokkuToplevel *toplevel);
void dokku_toplevel_close(DokkuToplevel *toplevel);
void dokku_toplevel_set_minimized(DokkuToplevel *toplevel, gboolean minimized);

#endif
