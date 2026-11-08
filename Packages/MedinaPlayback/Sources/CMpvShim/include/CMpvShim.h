#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#ifdef __cplusplus
extern "C" {
#endif

mpv_render_context *medina_mpv_render_create(mpv_handle *handle);
int medina_mpv_render_draw(mpv_render_context *context, int width, int height);
void medina_mpv_render_report_swap(mpv_render_context *context);
void medina_mpv_render_free(mpv_render_context *context);
void medina_mpv_enable_timing_events(mpv_handle *handle);
int medina_mpv_poll_timing_events(mpv_handle *handle);
enum {
    MEDINA_MPV_EVENT_FILE_LOADED = 1 << 0,
    MEDINA_MPV_EVENT_PLAYBACK_RESTART = 1 << 1
};

int medina_mpv_load(mpv_handle *handle, const char *url);
int medina_mpv_add_subtitle(mpv_handle *handle, const char *url, const char *name);
int medina_mpv_path_matches(mpv_handle *handle, const char *url);
int medina_mpv_get_track_count(mpv_handle *handle);
int medina_mpv_get_track(mpv_handle *handle, int index, char *id, int id_size,
                         char *type, int type_size, char *title, int title_size,
                         char *language, int language_size, int *selected);
int medina_mpv_get_buffered_ranges(mpv_handle *handle, double *ranges, int capacity);

#ifdef __cplusplus
}
#endif
