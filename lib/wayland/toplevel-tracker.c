#include "toplevel-tracker.h"

#include <string.h>
#include <wayland-client.h>
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"

typedef struct {
    struct wl_output *output;
    struct zxdg_output_v1 *xdg_output;
    uint32_t name;          /* the registry name, to recognise its removal */
    int x, y;
    struct _DokkuToplevelTracker *tracker;
} Output;

struct _DokkuToplevel {
    DokkuToplevelTracker *tracker;
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char *title;
    char *app_id;
    uint32_t state;
    GSList *outputs;            /* the outputs (struct wl_output *) the window is on */
    gboolean announced;         /* ADDED has been sent */
};

typedef struct {
    GSource source;
    DokkuToplevelTracker *tracker;
    GPollFD fd;
    gboolean reading;
} WaylandSource;

struct _DokkuToplevelTracker {
    struct wl_display *display;
    struct wl_registry *registry;
    struct zwlr_foreign_toplevel_manager_v1 *manager;
    struct zxdg_output_manager_v1 *xdg_output_manager;
    struct wl_seat *seat;
    GSList *toplevels;
    GSList *outputs;
    DokkuToplevelFunc func;
    void *data;
    WaylandSource *source;
};

/* --- Outputs --- */

static Output *find_output(DokkuToplevelTracker *t, struct wl_output *wl_output) {
    for (GSList *l = t->outputs; l != NULL; l = l->next) {
        Output *o = l->data;
        if (o->output == wl_output) return o;
    }
    return NULL;
}

static void notify_toplevels_on(DokkuToplevelTracker *t, struct wl_output *wl_output) {
    for (GSList *l = t->toplevels; l != NULL; l = l->next) {
        DokkuToplevel *tl = l->data;
        if (tl->announced && g_slist_find(tl->outputs, wl_output) != NULL) t->func(DOKKU_TOPLEVEL_CHANGED, tl, t->data);
    }
}

static void set_output_origin(DokkuToplevelTracker *t, Output *o, int x, int y) {
    if (o->x == x && o->y == y) return;
    o->x = x;
    o->y = y;
    notify_toplevels_on(t, o->output);
}

/* wlroots reports 0,0 here whatever the layout is; xdg-output has the real position.
 * This is only the fallback for a compositor without xdg-output. */
static void output_geometry(void *data, struct wl_output *wl_output, int32_t x, int32_t y,
                            int32_t pw, int32_t ph, int32_t subpixel, const char *make,
                            const char *model, int32_t transform) {
    DokkuToplevelTracker *t = data;
    Output *o = find_output(t, wl_output);
    if (o != NULL && o->xdg_output == NULL) set_output_origin(t, o, x, y);
}

static void xdg_output_position(void *data, struct zxdg_output_v1 *xdg_output, int32_t x, int32_t y) {
    Output *o = data;
    set_output_origin(o->tracker, o, x, y);
}

static void xdg_output_size(void *data, struct zxdg_output_v1 *x, int32_t w, int32_t h) {}
static void xdg_output_done(void *data, struct zxdg_output_v1 *x) {}
static void xdg_output_name(void *data, struct zxdg_output_v1 *x, const char *name) {}
static void xdg_output_description(void *data, struct zxdg_output_v1 *x, const char *d) {}

static const struct zxdg_output_v1_listener xdg_output_listener = {
    .logical_position = xdg_output_position,
    .logical_size = xdg_output_size,
    .done = xdg_output_done,
    .name = xdg_output_name,
    .description = xdg_output_description,
};

static void watch_xdg_output(DokkuToplevelTracker *t, Output *o) {
    if (t->xdg_output_manager == NULL || o->xdg_output != NULL) return;
    o->xdg_output = zxdg_output_manager_v1_get_xdg_output(t->xdg_output_manager, o->output);
    zxdg_output_v1_add_listener(o->xdg_output, &xdg_output_listener, o);
}

static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t r) {}
static void output_done(void *data, struct wl_output *o) {}
static void output_scale(void *data, struct wl_output *o, int32_t factor) {}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
};

/* --- Toplevels --- */

static void toplevel_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *title) {
    DokkuToplevel *tl = data;
    g_free(tl->title);
    tl->title = g_strdup(title);
}

static void toplevel_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *app_id) {
    DokkuToplevel *tl = data;
    g_free(tl->app_id);
    tl->app_id = g_strdup(app_id);
}

static void toplevel_output_enter(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
                                  struct wl_output *output) {
    DokkuToplevel *tl = data;
    if (g_slist_find(tl->outputs, output) == NULL) tl->outputs = g_slist_prepend(tl->outputs, output);
}

static void toplevel_output_leave(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
                                  struct wl_output *output) {
    DokkuToplevel *tl = data;
    tl->outputs = g_slist_remove(tl->outputs, output);
}

static void toplevel_state(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
                           struct wl_array *state) {
    DokkuToplevel *tl = data;
    uint32_t flags = 0;
    uint32_t *entry;
    wl_array_for_each(entry, state) {
        switch (*entry) {
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED:
                flags |= DOKKU_TOPLEVEL_STATE_MAXIMIZED; break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED:
                flags |= DOKKU_TOPLEVEL_STATE_MINIMIZED; break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED:
                flags |= DOKKU_TOPLEVEL_STATE_ACTIVATED; break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN:
                flags |= DOKKU_TOPLEVEL_STATE_FULLSCREEN; break;
        }
    }
    tl->state = flags;
}

static void toplevel_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *h) {
    DokkuToplevel *tl = data;
    DokkuToplevelTracker *t = tl->tracker;
    DokkuToplevelEvent event = tl->announced ? DOKKU_TOPLEVEL_CHANGED : DOKKU_TOPLEVEL_ADDED;
    tl->announced = TRUE;
    t->func(event, tl, t->data);
}

static void toplevel_free(DokkuToplevel *tl) {
    if (tl->handle != NULL) zwlr_foreign_toplevel_handle_v1_destroy(tl->handle);
    g_slist_free(tl->outputs);
    g_free(tl->title);
    g_free(tl->app_id);
    g_free(tl);
}

static void toplevel_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *h) {
    DokkuToplevel *tl = data;
    DokkuToplevelTracker *t = tl->tracker;
    t->toplevels = g_slist_remove(t->toplevels, tl);
    if (tl->announced) t->func(DOKKU_TOPLEVEL_CLOSED, tl, t->data);
    toplevel_free(tl);
}

static void toplevel_parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
                            struct zwlr_foreign_toplevel_handle_v1 *parent) {}

static const struct zwlr_foreign_toplevel_handle_v1_listener toplevel_listener = {
    .title = toplevel_title,
    .app_id = toplevel_app_id,
    .output_enter = toplevel_output_enter,
    .output_leave = toplevel_output_leave,
    .state = toplevel_state,
    .done = toplevel_done,
    .closed = toplevel_closed,
    .parent = toplevel_parent,
};

static void manager_toplevel(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager,
                             struct zwlr_foreign_toplevel_handle_v1 *handle) {
    DokkuToplevelTracker *t = data;
    DokkuToplevel *tl = g_new0(DokkuToplevel, 1);
    tl->tracker = t;
    tl->handle = handle;
    t->toplevels = g_slist_prepend(t->toplevels, tl);
    zwlr_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_listener, tl);
}

static void manager_finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager) {
    DokkuToplevelTracker *t = data;
    zwlr_foreign_toplevel_manager_v1_destroy(manager);
    t->manager = NULL;
}

static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = {
    .toplevel = manager_toplevel,
    .finished = manager_finished,
};

/* --- Registry --- */

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    DokkuToplevelTracker *t = data;
    if (strcmp(interface, zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
        t->manager = wl_registry_bind(registry, name, &zwlr_foreign_toplevel_manager_v1_interface,
                                      MIN(version, 3));
        zwlr_foreign_toplevel_manager_v1_add_listener(t->manager, &manager_listener, t);
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && t->seat == NULL) {
        t->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        Output *o = g_new0(Output, 1);
        o->name = name;
        o->tracker = t;
        o->output = wl_registry_bind(registry, name, &wl_output_interface, MIN(version, 2));
        t->outputs = g_slist_prepend(t->outputs, o);
        wl_output_add_listener(o->output, &output_listener, t);
        watch_xdg_output(t, o);
    } else if (strcmp(interface, zxdg_output_manager_v1_interface.name) == 0) {
        t->xdg_output_manager = wl_registry_bind(registry, name, &zxdg_output_manager_v1_interface,
                                                 MIN(version, 2));
        for (GSList *l = t->outputs; l != NULL; l = l->next) watch_xdg_output(t, l->data);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    DokkuToplevelTracker *t = data;
    for (GSList *l = t->outputs; l != NULL; l = l->next) {
        Output *o = l->data;
        if (o->name != name) continue;
        for (GSList *w = t->toplevels; w != NULL; w = w->next) {
            DokkuToplevel *tl = w->data;
            tl->outputs = g_slist_remove(tl->outputs, o->output);
        }
        t->outputs = g_slist_remove(t->outputs, o);
        if (o->xdg_output != NULL) zxdg_output_v1_destroy(o->xdg_output);
        wl_output_destroy(o->output);
        g_free(o);
        return;
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

/* --- GLib main loop integration --- */

static gboolean source_prepare(GSource *base, gint *timeout) {
    WaylandSource *s = (WaylandSource *) base;
    struct wl_display *display = s->tracker->display;
    *timeout = -1;

    /* Events already queued must be dispatched before polling for more */
    if (wl_display_prepare_read(display) != 0) return TRUE;
    wl_display_flush(display);
    s->reading = TRUE;
    return FALSE;
}

static gboolean source_check(GSource *base) {
    WaylandSource *s = (WaylandSource *) base;
    struct wl_display *display = s->tracker->display;

    if (s->reading) {
        s->reading = FALSE;
        if (s->fd.revents & G_IO_IN) wl_display_read_events(display);
        else wl_display_cancel_read(display);
    }
    return (s->fd.revents & (G_IO_IN | G_IO_ERR | G_IO_HUP)) != 0;
}

static gboolean source_dispatch(GSource *base, GSourceFunc callback, gpointer user_data) {
    WaylandSource *s = (WaylandSource *) base;
    struct wl_display *display = s->tracker->display;

    if (s->fd.revents & (G_IO_ERR | G_IO_HUP)) {
        /* The compositor went away; windows can no longer be tracked */
        g_warning("Lost the Wayland connection used for window tracking");
        return G_SOURCE_REMOVE;
    }
    if (wl_display_dispatch_pending(display) < 0) return G_SOURCE_REMOVE;
    wl_display_flush(display);
    return G_SOURCE_CONTINUE;
}

static GSourceFuncs source_funcs = {
    source_prepare, source_check, source_dispatch, NULL, NULL, NULL
};

/* --- Public API --- */

DokkuToplevelTracker *dokku_toplevel_tracker_new(DokkuToplevelFunc func, void *data) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) return NULL;

    DokkuToplevelTracker *t = g_new0(DokkuToplevelTracker, 1);
    t->display = display;
    t->func = func;
    t->data = data;
    t->registry = wl_display_get_registry(display);
    wl_registry_add_listener(t->registry, &registry_listener, t);

    /* One round trip learns the globals; a second delivers the windows that already
     * exist and the outputs' positions. */
    wl_display_roundtrip(display);
    if (t->manager == NULL || t->seat == NULL) {
        dokku_toplevel_tracker_free(t);
        return NULL;
    }
    wl_display_roundtrip(display);

    t->source = (WaylandSource *) g_source_new(&source_funcs, sizeof(WaylandSource));
    t->source->tracker = t;
    t->source->fd.fd = wl_display_get_fd(display);
    t->source->fd.events = G_IO_IN | G_IO_ERR | G_IO_HUP;
    g_source_add_poll((GSource *) t->source, &t->source->fd);
    g_source_attach((GSource *) t->source, NULL);
    return t;
}

void dokku_toplevel_tracker_free(DokkuToplevelTracker *t) {
    if (t == NULL) return;
    if (t->source != NULL) {
        g_source_destroy((GSource *) t->source);
        g_source_unref((GSource *) t->source);
    }
    for (GSList *l = t->toplevels; l != NULL; l = l->next) toplevel_free(l->data);
    g_slist_free(t->toplevels);
    for (GSList *l = t->outputs; l != NULL; l = l->next) {
        Output *o = l->data;
        if (o->xdg_output != NULL) zxdg_output_v1_destroy(o->xdg_output);
        wl_output_destroy(o->output);
        g_free(o);
    }
    g_slist_free(t->outputs);
    if (t->xdg_output_manager != NULL) zxdg_output_manager_v1_destroy(t->xdg_output_manager);
    if (t->manager != NULL) zwlr_foreign_toplevel_manager_v1_destroy(t->manager);
    if (t->seat != NULL) wl_seat_destroy(t->seat);
    wl_registry_destroy(t->registry);
    wl_display_disconnect(t->display);
    g_free(t);
}

const char *dokku_toplevel_get_title(DokkuToplevel *tl) {
    return tl->title != NULL ? tl->title : "";
}

const char *dokku_toplevel_get_app_id(DokkuToplevel *tl) {
    return tl->app_id != NULL ? tl->app_id : "";
}

uint32_t dokku_toplevel_get_state(DokkuToplevel *tl) {
    return tl->state;
}

gboolean dokku_toplevel_is_on_output_at(DokkuToplevel *tl, int x, int y) {
    for (GSList *l = tl->outputs; l != NULL; l = l->next) {
        Output *o = find_output(tl->tracker, l->data);
        if (o != NULL && o->x == x && o->y == y) return TRUE;
    }
    return FALSE;
}

void dokku_toplevel_activate(DokkuToplevel *tl) {
    zwlr_foreign_toplevel_handle_v1_activate(tl->handle, tl->tracker->seat);
    wl_display_flush(tl->tracker->display);
}

void dokku_toplevel_close(DokkuToplevel *tl) {
    zwlr_foreign_toplevel_handle_v1_close(tl->handle);
    wl_display_flush(tl->tracker->display);
}

void dokku_toplevel_set_minimized(DokkuToplevel *tl, gboolean minimized) {
    if (minimized) zwlr_foreign_toplevel_handle_v1_set_minimized(tl->handle);
    else zwlr_foreign_toplevel_handle_v1_unset_minimized(tl->handle);
    wl_display_flush(tl->tracker->display);
}
