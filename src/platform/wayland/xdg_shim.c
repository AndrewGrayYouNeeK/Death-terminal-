#include "xdg-shell-client-protocol.h"
#include "xdg_shim.h"

struct xdg_wm_base *dt_xdg_bind(struct wl_registry *registry, uint32_t name, uint32_t version) {
    return wl_registry_bind(registry, name, &xdg_wm_base_interface, version);
}

struct xdg_surface *dt_xdg_get_surface(struct xdg_wm_base *base, struct wl_surface *surface) {
    return xdg_wm_base_get_xdg_surface(base, surface);
}

struct xdg_toplevel *dt_xdg_get_toplevel(struct xdg_surface *surface) {
    return xdg_surface_get_toplevel(surface);
}

void dt_xdg_wm_base_destroy(struct xdg_wm_base *base) {
    xdg_wm_base_destroy(base);
}

void dt_xdg_wm_base_pong(struct xdg_wm_base *base, uint32_t serial) {
    xdg_wm_base_pong(base, serial);
}

void dt_xdg_surface_destroy(struct xdg_surface *surface) {
    xdg_surface_destroy(surface);
}

void dt_xdg_surface_ack_configure(struct xdg_surface *surface, uint32_t serial) {
    xdg_surface_ack_configure(surface, serial);
}

void dt_xdg_toplevel_destroy(struct xdg_toplevel *toplevel) {
    xdg_toplevel_destroy(toplevel);
}

void dt_xdg_toplevel_set_title(struct xdg_toplevel *toplevel, const char *title) {
    xdg_toplevel_set_title(toplevel, title);
}

void dt_xdg_toplevel_set_app_id(struct xdg_toplevel *toplevel, const char *app_id) {
    xdg_toplevel_set_app_id(toplevel, app_id);
}

struct WmBaseData {
    dt_xdg_ping_fn ping;
    void *user;
};

struct SurfaceData {
    dt_xdg_surface_configure_fn configure;
    void *user;
};

struct ToplevelData {
    dt_xdg_toplevel_configure_fn configure;
    dt_xdg_toplevel_close_fn close_fn;
    void *user;
};

static void ping_cb(void *data, struct xdg_wm_base *base, uint32_t serial) {
    struct WmBaseData *d = data;
    (void)base;
    if (d && d->ping) d->ping(d->user, serial);
}

static void surface_configure_cb(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct SurfaceData *d = data;
    (void)surface;
    if (d && d->configure) d->configure(d->user, serial);
}

static void toplevel_configure_cb(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    struct ToplevelData *d = data;
    (void)toplevel;
    (void)states;
    if (d && d->configure) d->configure(d->user, width, height);
}

static void toplevel_close_cb(void *data, struct xdg_toplevel *toplevel) {
    struct ToplevelData *d = data;
    (void)toplevel;
    if (d && d->close_fn) d->close_fn(d->user);
}

static const struct xdg_wm_base_listener wm_listener = { .ping = ping_cb };
static const struct xdg_surface_listener surface_listener = { .configure = surface_configure_cb };
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure_cb,
    .close = toplevel_close_cb,
};

static struct WmBaseData wm_data;
static struct SurfaceData surface_data;
static struct ToplevelData toplevel_data;

void dt_xdg_listen_wm_base(struct xdg_wm_base *base, void *data, dt_xdg_ping_fn ping) {
    wm_data.ping = ping;
    wm_data.user = data;
    xdg_wm_base_add_listener(base, &wm_listener, &wm_data);
}

void dt_xdg_listen_surface(struct xdg_surface *surface, void *data, dt_xdg_surface_configure_fn configure) {
    surface_data.configure = configure;
    surface_data.user = data;
    xdg_surface_add_listener(surface, &surface_listener, &surface_data);
}

void dt_xdg_listen_toplevel(struct xdg_toplevel *toplevel, void *data, dt_xdg_toplevel_configure_fn configure, dt_xdg_toplevel_close_fn close_fn) {
    toplevel_data.configure = configure;
    toplevel_data.close_fn = close_fn;
    toplevel_data.user = data;
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, &toplevel_data);
}
