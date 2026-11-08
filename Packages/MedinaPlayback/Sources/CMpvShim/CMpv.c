#include "CMpvShim.h"
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void *get_gl_proc(void *ctx, const char *name) {
    (void)ctx;
    return dlsym(RTLD_DEFAULT, name);
}

mpv_render_context *medina_mpv_render_create(mpv_handle *handle) {
    mpv_opengl_init_params gl = { .get_proc_address = get_gl_proc, .get_proc_address_ctx = NULL };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    mpv_render_context *context = NULL;
    if (mpv_render_context_create(&context, handle, params) < 0) return NULL;
    return context;
}

int medina_mpv_render_draw(mpv_render_context *context, int width, int height) {
    if (!context || width <= 0 || height <= 0) return 0;
    mpv_opengl_fbo fbo = { .fbo = 0, .w = width, .h = height, .internal_format = 0 };
    int flip_y = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    unsigned int flags = mpv_render_context_update(context);
    mpv_render_context_render(context, params);
    return (flags & MPV_RENDER_UPDATE_FRAME) != 0;
}

void medina_mpv_enable_timing_events(mpv_handle *handle) {
    if (!handle) return;
    mpv_request_event(handle, MPV_EVENT_FILE_LOADED, 1);
    mpv_request_event(handle, MPV_EVENT_PLAYBACK_RESTART, 1);
}

int medina_mpv_poll_timing_events(mpv_handle *handle) {
    if (!handle) return 0;
    int flags = 0;
    for (int i = 0; i < 64; ++i) {
        const mpv_event *event = mpv_wait_event(handle, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        if (event->event_id == MPV_EVENT_FILE_LOADED) flags |= MEDINA_MPV_EVENT_FILE_LOADED;
        if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) flags |= MEDINA_MPV_EVENT_PLAYBACK_RESTART;
    }
    return flags;
}

void medina_mpv_render_report_swap(mpv_render_context *context) {
    if (context) mpv_render_context_report_swap(context);
}

void medina_mpv_render_free(mpv_render_context *context) {
    if (context) mpv_render_context_free(context);
}

int medina_mpv_load(mpv_handle *handle, const char *url) {
    const char *args[] = { "loadfile", url, "replace", NULL };
    return mpv_command(handle, args);
}

int medina_mpv_add_subtitle(mpv_handle *handle, const char *url, const char *name) {
    const char *args[] = { "sub-add", url, "select", name, NULL };
    return mpv_command(handle, args);
}

static void copy_node_string(mpv_node *map, const char *key, char *output, int size) {
    if (!output || size <= 0) return;
    output[0] = '\0';
    if (!map || map->format != MPV_FORMAT_NODE_MAP || !map->u.list) return;
    mpv_node_list *list = map->u.list;
    for (int i = 0; i < list->num; ++i) {
        if (!list->keys[i] || strcmp(list->keys[i], key) != 0) continue;
        if (list->values[i].format == MPV_FORMAT_STRING) {
            snprintf(output, (size_t)size, "%s", list->values[i].u.string ? list->values[i].u.string : "");
        } else if (list->values[i].format == MPV_FORMAT_INT64) {
            snprintf(output, (size_t)size, "%lld", (long long)list->values[i].u.int64);
        }
        return;
    }
}

int medina_mpv_path_matches(mpv_handle *handle, const char *url) {
    char *path = mpv_get_property_string(handle, "path");
    if (!path) return 0;
    int matches = strcmp(path, url) == 0;
    mpv_free(path);
    return matches;
}

int medina_mpv_get_track_count(mpv_handle *handle) {
    mpv_node tracks = {0};
    if (mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &tracks) < 0) return 0;
    int count = tracks.format == MPV_FORMAT_NODE_ARRAY && tracks.u.list ? tracks.u.list->num : 0;
    mpv_free_node_contents(&tracks);
    return count;
}

int medina_mpv_get_buffered_ranges(mpv_handle *handle, double *ranges, int capacity) {
    if (!handle || !ranges || capacity <= 0) return 0;
    mpv_node state = {0};
    if (mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &state) < 0) {
        mpv_free_node_contents(&state);
        return 0;
    }

    int count = 0;
    if (state.format == MPV_FORMAT_NODE_MAP && state.u.list) {
        mpv_node *range_list = NULL;
        mpv_node_list *map = state.u.list;
        for (int i = 0; i < map->num; ++i) {
            if (map->keys[i] && strcmp(map->keys[i], "seekable-ranges") == 0) {
                range_list = &map->values[i];
                break;
            }
        }
        if (range_list && range_list->format == MPV_FORMAT_NODE_ARRAY && range_list->u.list) {
            mpv_node_list *items = range_list->u.list;
            for (int i = 0; i < items->num && count < capacity; ++i) {
                mpv_node *item = &items->values[i];
                double start = 0, end = 0;
                int has_start = 0, has_end = 0;
                if (item->format != MPV_FORMAT_NODE_MAP || !item->u.list) continue;
                mpv_node_list *fields = item->u.list;
                for (int j = 0; j < fields->num; ++j) {
                    if (!fields->keys[j]) continue;
                    mpv_node *value = &fields->values[j];
                    double number;
                    if (value->format == MPV_FORMAT_DOUBLE) number = value->u.double_;
                    else if (value->format == MPV_FORMAT_INT64) number = (double)value->u.int64;
                    else continue;
                    if (strcmp(fields->keys[j], "start") == 0) { start = number; has_start = 1; }
                    if (strcmp(fields->keys[j], "end") == 0) { end = number; has_end = 1; }
                }
                if (!has_start || !has_end || !isfinite(start) || !isfinite(end) || end <= start) continue;
                ranges[count * 2] = start;
                ranges[count * 2 + 1] = end;
                ++count;
            }
        }
    }
    mpv_free_node_contents(&state);
    return count;
}

int medina_mpv_get_track(mpv_handle *handle, int index, char *id, int id_size,
                         char *type, int type_size, char *title, int title_size,
                         char *language, int language_size, int *selected) {
    mpv_node tracks = {0};
    if (mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &tracks) < 0) return 0;
    if (tracks.format != MPV_FORMAT_NODE_ARRAY || !tracks.u.list || index < 0 || index >= tracks.u.list->num) {
        mpv_free_node_contents(&tracks);
        return 0;
    }
    mpv_node *node = &tracks.u.list->values[index];
    copy_node_string(node, "id", id, id_size);
    copy_node_string(node, "type", type, type_size);
    copy_node_string(node, "title", title, title_size);
    copy_node_string(node, "lang", language, language_size);
    if (selected) {
        *selected = 0;
        if (node->format == MPV_FORMAT_NODE_MAP && node->u.list) {
            mpv_node_list *list = node->u.list;
            for (int i = 0; i < list->num; ++i) {
                if (list->keys[i] && strcmp(list->keys[i], "selected") == 0 && list->values[i].format == MPV_FORMAT_FLAG) {
                    *selected = list->values[i].u.flag;
                    break;
                }
            }
        }
    }
    mpv_free_node_contents(&tracks);
    return 1;
}
