#pragma once

#include <stdint.h>

struct wl_registry;
struct wl_surface;
struct wl_array;
struct xdg_wm_base;
struct xdg_surface;
struct xdg_toplevel;

struct xdg_wm_base *dt_xdg_bind(struct wl_registry *registry, uint32_t name, uint32_t version);
struct xdg_surface *dt_xdg_get_surface(struct xdg_wm_base *base, struct wl_surface *surface);
struct xdg_toplevel *dt_xdg_get_toplevel(struct xdg_surface *surface);
void dt_xdg_wm_base_destroy(struct xdg_wm_base *base);
void dt_xdg_wm_base_pong(struct xdg_wm_base *base, uint32_t serial);
void dt_xdg_surface_destroy(struct xdg_surface *surface);
void dt_xdg_surface_ack_configure(struct xdg_surface *surface, uint32_t serial);
void dt_xdg_toplevel_destroy(struct xdg_toplevel *toplevel);
void dt_xdg_toplevel_set_title(struct xdg_toplevel *toplevel, const char *title);
void dt_xdg_toplevel_set_app_id(struct xdg_toplevel *toplevel, const char *app_id);

typedef void (*dt_xdg_ping_fn)(void *data, uint32_t serial);
typedef void (*dt_xdg_surface_configure_fn)(void *data, uint32_t serial);
typedef void (*dt_xdg_toplevel_configure_fn)(void *data, int32_t width, int32_t height);
typedef void (*dt_xdg_toplevel_close_fn)(void *data);

void dt_xdg_listen_wm_base(struct xdg_wm_base *base, void *data, dt_xdg_ping_fn ping);
void dt_xdg_listen_surface(struct xdg_surface *surface, void *data, dt_xdg_surface_configure_fn configure);
void dt_xdg_listen_toplevel(struct xdg_toplevel *toplevel, void *data, dt_xdg_toplevel_configure_fn configure, dt_xdg_toplevel_close_fn close_fn);
