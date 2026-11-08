/* LD_PRELOAD shim for Steam's UI (steamwebhelper, Chromium 126 with ANGLE on Vulkan) under gamescope.
 *
 * Chromium puts its windows on the 32-bit ARGB visual when a compositing manager runs (gamescope does) and asks EGL
 * for a config with that EGL_NATIVE_VISUAL_ID (ui/gl/gl_surface_egl_x11.cc GetNativeVisualID). ANGLE's Vulkan
 * backend labels all its configs with the screen's root visual (DisplayVkXcb::checkConfigSupport, from
 * xcb_get_setup), so no config matches, eglCreateWindowSurface fails with EGL_BAD_CONFIG and the UI falls back to
 * software compositing. This shim answers xcb_get_setup calls made from ANGLE (libGLESv2.so) with a copy of the
 * setup whose first screen's root_visual is the ARGB visual Chromium picks: the same GLX scoring as
 * ui/gfx/x/visual_picker_glx.cc PickBestGlVisual (Xwayland has several identical 32-bit visuals), falling back to
 * the first 32-bit 8888 visual. All other callers get the real setup.
 *
 * No headers (built on the Mac): clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fuse-ld=lld \
 *   -o angle-argb-visual.so angle-argb-visual.c */
typedef unsigned long size_t;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

void *dlsym(void *handle, const char *name);
int dladdr(const void *addr, void *info);
void *malloc(size_t n);
void free(void *p);
void *dlopen(const char *file, int mode);
void *memcpy(void *d, const void *s, size_t n);
char *strstr(const char *h, const char *n);
#define RTLD_NEXT ((void *)-1l)

typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } dl_info;
typedef struct { u8 status, pad0; u16 major, minor, length; u32 release, rid_base, rid_mask, motion_buf;
                 u16 vendor_len, max_req_len; u8 roots_len, formats_len; } xcb_setup;
typedef struct { u32 root, default_colormap, white, black, input_masks; u16 w, h, wmm, hmm, min_maps, max_maps;
                 u32 root_visual; u8 backing, save_unders, root_depth, depths_len; } xcb_screen;
typedef struct { u8 depth, pad0; u16 visuals_len; u8 pad1[4]; } xcb_depth;
typedef struct { u32 visual_id; u8 cls, bits; u16 entries; u32 red, green, blue; u8 pad[4]; } xcb_visualtype;
typedef struct { void *data; int rem, index; } iter;

static const xcb_setup *(*real_get_setup)(void *);
static iter (*roots_iterator)(const xcb_setup *);
static iter (*depths_iterator)(const xcb_screen *);
static void (*depth_next)(iter *);
static xcb_visualtype *(*depth_visuals)(const xcb_depth *);
typedef struct { u8 type, pad0; u16 seq; u32 length, num_visuals, num_properties; u8 pad1[16]; } glx_configs_reply;
static void *last_conn;
static xcb_setup *patched;

static int from_angle(void *caller)
{
    dl_info info = {0};
    return dladdr(caller, &info) && info.fname && strstr(info.fname, "libGLESv2");
}

static int visual_depth(xcb_screen *screen, u32 id, int *argb)
{
    for (iter d = depths_iterator(screen); d.rem; depth_next(&d)) {
        xcb_depth *depth = d.data;
        xcb_visualtype *v = depth_visuals(depth);
        for (int i = 0; i < depth->visuals_len; i++)
            if (v[i].visual_id == id) {
                *argb = depth->depth == 32 && v[i].red == 0xff0000 && v[i].green == 0xff00 && v[i].blue == 0xff;
                return depth->depth;
            }
    }
    return 0;
}

/* Chromium's PickBestGlVisual(IsArgbVisual, want_alpha = true); 0 if GLX is unavailable */
static u32 glx_argb_visual(void *conn, xcb_screen *screen)
{
    void *glx = dlopen("libxcb-glx.so.0", 1 /* RTLD_LAZY */);
    if (!glx) return 0;
    unsigned (*request)(void *, u32) = dlsym(glx, "xcb_glx_get_visual_configs");
    glx_configs_reply *(*reply_of)(void *, unsigned, void *) = dlsym(glx, "xcb_glx_get_visual_configs_reply");
    u32 *(*props_of)(const glx_configs_reply *) = dlsym(glx, "xcb_glx_get_visual_configs_property_list");
    if (!request || !reply_of || !props_of) return 0;
    glx_configs_reply *r = reply_of(conn, request(conn, 0), 0);
    if (!r) return 0;
    enum { VISUAL_ID, X_VISUAL_TYPE, RENDER_TYPE, RED, GREEN, BLUE, ALPHA, AR, AG, AB, AA, DOUBLEBUFFER, STEREO,
           BUFFER_SIZE, DEPTH, STENCIL, AUX, LEVEL, STATIC_PROPS };
    u32 best = 0, *list = props_of(r);
    int best_score = -1;
    for (u32 c = 0; r->num_properties >= STATIC_PROPS && c < r->num_visuals; c++) {
        u32 *p = list + (size_t)c * r->num_properties, caveat = 0, samples = 0;
        for (u32 j = STATIC_PROPS; j + 1 < r->num_properties; j += 2) {
            if (p[j] == 0x20) caveat = p[j + 1];          /* GLX_VISUAL_CAVEAT_EXT */
            if (p[j] == 100000) samples = p[j + 1];       /* GLX_SAMPLE_BUFFERS_ARB */
        }
        int argb = 0;
        if (!visual_depth(screen, p[VISUAL_ID], &argb) || !argb || !p[DOUBLEBUFFER] || p[STEREO] ||
            (caveat && caveat != 0x8000))
            continue;
        int score = 0;
        if (!samples) {
            score++;
            if (!p[DEPTH] && !p[STENCIL]) score += 1 + (p[ALPHA] > 0);
        }
        if (score > best_score) best_score = score, best = p[VISUAL_ID];
    }
    free(r);
    return best;
}

static xcb_setup *patch(void *conn, const xcb_setup *s)
{
    size_t size = 8 + (size_t)s->length * 4;
    xcb_setup *copy = malloc(size);
    if (!copy) return 0;
    memcpy(copy, s, size);
    xcb_screen *screen = roots_iterator(copy).data;
    u32 glx = glx_argb_visual(conn, screen);
    if (glx) {
        screen->root_visual = glx;
        return copy;
    }
    for (iter d = depths_iterator(screen); d.rem; depth_next(&d)) {
        xcb_depth *depth = d.data;
        xcb_visualtype *v = depth_visuals(depth);
        for (int i = 0; depth->depth == 32 && i < depth->visuals_len; i++)
            if (v[i].red == 0xff0000 && v[i].green == 0xff00 && v[i].blue == 0xff) {
                screen->root_visual = v[i].visual_id;
                return copy;
            }
    }
    return copy;
}

const xcb_setup *xcb_get_setup(void *conn)
{
    if (!real_get_setup) {
        real_get_setup = dlsym(RTLD_NEXT, "xcb_get_setup");
        roots_iterator = dlsym(RTLD_NEXT, "xcb_setup_roots_iterator");
        depths_iterator = dlsym(RTLD_NEXT, "xcb_screen_allowed_depths_iterator");
        depth_next = dlsym(RTLD_NEXT, "xcb_depth_next");
        depth_visuals = dlsym(RTLD_NEXT, "xcb_depth_visuals");
    }
    const xcb_setup *s = real_get_setup(conn);
    if (!s || !roots_iterator || !depths_iterator || !depth_next || !depth_visuals ||
        !from_angle(__builtin_return_address(0)))
        return s;
    if (conn != last_conn) { /* one ANGLE connection per process; a leaked copy per new one is fine */
        patched = patch(conn, s);
        last_conn = conn;
    }
    return patched ? patched : s;
}
