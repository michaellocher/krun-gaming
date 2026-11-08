// Gaming spike launcher (libkrun 1.19 API): ext4 disk or directory root, own kernel, virtio-gpu with Venus (Vulkan
// forwarded to MoltenVK on the host), optional network via TSI, and with --display a macOS window that shows the
// guest's scanout (KMS) — the "stream machine" without encoding: guest frames land in IOSurfaces that the window's
// layer composites directly.
// usage: vm-gpu [--ram MiB] [--vcpus N] [--vram MiB] [--net] [--share TAG:HOSTPATH]... [--env K=V]...
//               [--disk ID:IMAGE]... [--root-disk /dev/vdX] [--kernel IMAGE] [--display WxH] ROOT|- CMD [ARGS...]
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <getopt.h>
#include <libkrun.h>
#include <libkrun_display.h>
#include "net-slirp.h"
#import "input-mac.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(call) do { int32_t r_ = (call); if (r_ < 0) { fprintf(stderr, "%s failed: %s\n", #call, strerror(-r_)); return 1; } } while (0)

// ---- display backend: called by libkrun's GPU thread ----

enum { NFRAMES = 3 }; // the guest writes one surface while the window shows another
static struct {
    uint32_t width, height;
    IOSurfaceRef frames[NFRAMES];
    unsigned next;
} scanout;
static NSWindow *window;
static CALayer *screen;

static int32_t display_disable(void *instance, uint32_t scanout_id) {
    (void)instance;
    if (scanout_id != 0) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    dispatch_async(dispatch_get_main_queue(), ^{ screen.contents = nil; });
    return 0;
}

static int32_t display_configure(void *instance, uint32_t scanout_id, uint32_t display_w, uint32_t display_h, uint32_t w,
                                 uint32_t h, uint32_t format) {
    (void)instance; (void)display_w; (void)display_h;
    if (scanout_id != 0) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    // DRM's XRGB8888/ARGB8888 arrive as B8G8R8X8/B8G8R8A8, which is what a BGRA IOSurface stores
    if (format != KRUN_DISPLAY_FORMAT_B8G8R8A8_UNORM && format != KRUN_DISPLAY_FORMAT_B8G8R8X8_UNORM) {
        fprintf(stderr, "vm-gpu: scanout format %u not supported\n", format);
        return KRUN_DISPLAY_ERR_INVALID_PARAM;
    }
    for (int i = 0; i < NFRAMES; i++) {
        if (scanout.frames[i]) CFRelease(scanout.frames[i]);
        // rows exactly width*4 bytes: libkrun copies the guest rows without knowing our stride
        scanout.frames[i] = IOSurfaceCreate((__bridge CFDictionaryRef) @{
            (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
        if (!scanout.frames[i]) return KRUN_DISPLAY_ERR_INTERNAL;
    }
    scanout.width = w, scanout.height = h;
    fprintf(stderr, "vm-gpu: scanout %ux%u format %u\n", w, h, format);
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat scale = window.backingScaleFactor;
        [window setContentSize:NSMakeSize(w / scale, h / scale)]; // one guest pixel per screen pixel
        [window makeKeyAndOrderFront:nil];
    });
    return 0;
}

static int32_t display_alloc_frame(void *instance, uint32_t scanout_id, uint8_t **buffer, size_t *size) {
    (void)instance;
    if (scanout_id != 0) return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    unsigned i = scanout.next++ % NFRAMES;
    IOSurfaceLock(scanout.frames[i], 0, NULL);
    *buffer = IOSurfaceGetBaseAddress(scanout.frames[i]);
    *size = (size_t)scanout.width * scanout.height * 4;
    static int clear = -1; // VM_CLEAR_FRAMES=1: zero each frame first (shows whether libkrun really fills it)
    if (clear < 0) clear = getenv("VM_CLEAR_FRAMES") != NULL;
    if (clear) memset(*buffer, 0, *size);
    return (int32_t)i;
}

// VM_SNAPSHOT=/path.ppm [VM_SNAPSHOT_FRAME=n, default 1]: write the n-th presented frame as a PPM, for checks
// written to path.tmp and renamed, so readers never see a half-written file
static void snapshot_to(IOSurfaceRef surface, const char *path) {
    if (!path) return;
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    const uint8_t *px = IOSurfaceGetBaseAddress(surface);
    size_t n = (size_t)scanout.width * scanout.height;
    uint8_t *rgb = malloc(n * 3);
    for (size_t i = 0; i < n; i++) rgb[i * 3] = px[i * 4 + 2], rgb[i * 3 + 1] = px[i * 4 + 1], rgb[i * 3 + 2] = px[i * 4];
    fprintf(f, "P6\n%u %u\n255\n", scanout.width, scanout.height);
    fwrite(rgb, 3, n, f);
    fclose(f);
    free(rgb);
    rename(tmp, path);
}

static void snapshot(IOSurfaceRef surface) {
    snapshot_to(surface, getenv("VM_SNAPSHOT"));
    fprintf(stderr, "vm-gpu: snapshot written to %s\n", getenv("VM_SNAPSHOT"));
}

// VM_FRAME_STATS=1: per presented frame '#' (> 1 % of sampled pixels lit), '+' (some) or '.' (black), printed
// every 100 frames — makes flicker visible in the log. VM_SNAPSHOT_LIT=path: the latest lit frame, at most 1/s
static void frame_stats(IOSurfaceRef surface) {
    static char line[101];
    static unsigned n;
    static time_t last_lit;
    const uint32_t *px = IOSurfaceGetBaseAddress(surface);
    size_t count = (size_t)scanout.width * scanout.height, lit = 0, samples = 0;
    for (size_t i = 0; i < count; i += 61, samples++) lit += (px[i] & 0xffffff) != 0;
    // content fingerprint: '.' black, else a letter from a sample checksum — flicker between images shows as ABAB
    uint32_t sum = 0;
    static int corners = -1; // VM_FRAME_STATS=corners: fingerprint only the four 48x48 corners (gamescope --composite-debug)
    if (corners < 0) corners = getenv("VM_FRAME_STATS") && !strcmp(getenv("VM_FRAME_STATS"), "corners");
    if (corners) {
        for (unsigned y = 0; y < 48; y++)
            for (unsigned x = 0; x < 48; x++) {
                unsigned ys[2] = { y, scanout.height - 1 - y }, xs[2] = { x, scanout.width - 1 - x };
                for (int a = 0; a < 2; a++)
                    for (int b = 0; b < 2; b++) sum = sum * 31 + (px[(size_t)ys[a] * scanout.width + xs[b]] & 0xffffff);
            }
    } else {
        for (size_t i = 0; i < count; i += 997) sum = sum * 31 + (px[i] & 0xffffff);
    }
    line[n++] = lit * 100 > samples ? (char)('A' + sum % 26) : lit ? '+' : '.';
    if (lit && getenv("VM_SNAPSHOT_LIT") && time(NULL) != last_lit)
        last_lit = time(NULL), snapshot_to(surface, getenv("VM_SNAPSHOT_LIT"));
    if (n == 100) line[n] = 0, fprintf(stderr, "vm-gpu: frames %s\n", line), n = 0;
}

static int32_t display_present(void *instance, uint32_t scanout_id, uint32_t frame, const struct krun_rect *damage) {
    (void)instance; (void)damage;
    if (scanout_id != 0 || frame >= NFRAMES) return KRUN_DISPLAY_ERR_INVALID_PARAM;
    IOSurfaceRef surface = scanout.frames[frame];
    static int stats = -1;
    if (stats < 0) stats = getenv("VM_FRAME_STATS") != NULL;
    if (stats) frame_stats(surface);
    static unsigned presented;
    const char *at = getenv("VM_SNAPSHOT_FRAME"), *every = getenv("VM_SNAPSHOT_EVERY"); // every: n frames, overwrite
    ++presented;
    if (presented == (at ? (unsigned)atoi(at) : 1u) || (every && presented % (unsigned)atoi(every) == 0))
        snapshot(surface);
    if (presented <= 5 || presented % 100 == 0) fprintf(stderr, "vm-gpu: %u frames presented\n", presented);
    IOSurfaceUnlock(surface, 0, NULL);
    CFRetain(surface);
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        screen.contents = (__bridge id)surface;
        [CATransaction commit];
        CFRelease(surface);
    });
    return 0;
}

// shown right away (black until the guest sets a mode), so "no window" never hides a guest that shows nothing
static void open_window(unsigned w, unsigned h) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w / scale, h / scale)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    window.title = @"krun-gaming";
    window.contentView = [[InputView alloc] initWithFrame:window.contentView.frame]; // keyboard + mouse to the guest
    window.acceptsMouseMovedEvents = YES;
    window.contentView.wantsLayer = YES;
    screen = window.contentView.layer;
    [window makeFirstResponder:window.contentView];
    screen.backgroundColor = NSColor.blackColor.CGColor;
    screen.contentsGravity = kCAGravityResizeAspect;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:window queue:nil
                                                  usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---- VM ----

// VIRGL_LOG=1: virglrenderer only logs through a callback, which libkrun 1.19 never sets; register one that writes
// to stderr (found with dlsym in the virglrenderer libkrun already loaded, so no link-time dependency).
static void virgl_to_stderr(int level, const char *message, void *user) {
    (void)user;
    fprintf(stderr, "virgl[%d]: %s%s", level, message, message[0] && message[strlen(message) - 1] == '\n' ? "" : "\n");
}

static void enable_virgl_log(void) {
    if (!getenv("VIRGL_LOG")) return;
    void (*set_cb)(void (*)(int, const char *, void *), void *, void (*)(void *)) =
        dlsym(RTLD_DEFAULT, "virgl_set_log_callback");
    if (set_cb) set_cb(virgl_to_stderr, NULL, NULL);
    else fprintf(stderr, "vm-gpu: virgl_set_log_callback not found\n");
}

static void *run_vm(void *ctx) {
    int32_t r = krun_start_enter((uint32_t)(uintptr_t)ctx); // exits the process when the guest powers off
    fprintf(stderr, "krun_start_enter failed: %s\n", strerror(-r));
    exit(1);
}

int main(int argc, char *const argv[]) {
    unsigned ram = 4096, vcpus = 4, vram = 4096, net = 0, slirp = 0, nshare = 0, ndisk = 0, disp_w = 0, disp_h = 0;
    const char *shares[8] = { 0 }, *disks[8] = { 0 }, *root_disk = NULL, *kernel = NULL;
    const char *envs[128] = { "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 0 };
    int nenv = 1;
    static const struct option opts[] = { { "ram", 1, 0, 'r' }, { "vcpus", 1, 0, 'c' }, { "vram", 1, 0, 'g' },
        { "net", 0, 0, 'n' }, { "share", 1, 0, 's' }, { "env", 1, 0, 'e' }, { "disk", 1, 0, 'd' },
        { "root-disk", 1, 0, 'R' }, { "kernel", 1, 0, 'k' }, { "display", 1, 0, 'D' }, { "slirp", 0, 0, 'N' },
        { 0, 0, 0, 0 } };
    int c;
    while ((c = getopt_long(argc, argv, "+", opts, NULL)) != -1) {
        if (c == 'r') ram = (unsigned)atoi(optarg);
        else if (c == 'c') vcpus = (unsigned)atoi(optarg);
        else if (c == 'g') vram = (unsigned)atoi(optarg);
        else if (c == 'n') net = 1;
        else if (c == 'N') slirp = 1;
        else if (c == 's' && nshare < 8) shares[nshare++] = optarg;
        else if (c == 'd' && ndisk < 8) disks[ndisk++] = optarg;
        else if (c == 'R') root_disk = optarg;
        else if (c == 'k') kernel = optarg;
        else if (c == 'D' && sscanf(optarg, "%ux%u", &disp_w, &disp_h) == 2) {}
        else if (c == 'e' && strncmp(optarg, "PATH=", 5) == 0) envs[0] = optarg;
        else if (c == 'e' && nenv < 126) envs[nenv++] = optarg;
        else return 64;
    }
    envs[nenv] = NULL;
    if (argc - optind < 2) { fprintf(stderr, "usage: vm-gpu [options] ROOT|- CMD [ARGS] (see source header)\n"); return 64; }

    enable_virgl_log();
#ifdef VK_DRIVER_JSON // built against the Vulkan loader: point it at our driver unless the caller chose one
    if (VK_DRIVER_JSON[0]) setenv("VK_DRIVER_FILES", VK_DRIVER_JSON, 0);
#endif
    CHECK(krun_set_log_level(getenv("VM_LOG") ? (uint32_t)atoi(getenv("VM_LOG")) : 2)); // 0 off .. 5 trace
    int32_t ctx = krun_create_ctx();
    CHECK(ctx);
    CHECK(krun_set_vm_config(ctx, (uint8_t)vcpus, ram));
    // own raw arm64 Image instead of libkrunfw's; libkrun still adds its cmdline (init=/init.krun, root, command)
    if (kernel) CHECK(krun_set_kernel(ctx, kernel, KRUN_KERNEL_FORMAT_RAW, NULL, NULL));
    // ROOT "-" with --root-disk: libkrun boots init from a hidden virtiofs root, then switches to the ext4 disk
    if (strcmp(argv[optind], "-") != 0) CHECK(krun_set_root(ctx, argv[optind]));
    for (unsigned i = 0; i < ndisk; i++) { // --disk ID:IMAGE, raw images appear as /dev/vda, /dev/vdb, ... in order
        char *spec = strdup(disks[i]);
        char *path = strchr(spec, ':');
        if (!path) { fprintf(stderr, "--disk needs ID:IMAGE\n"); return 64; }
        *path++ = 0;
        CHECK(krun_add_disk(ctx, spec, path, false));
    }
    if (root_disk) CHECK(krun_set_root_disk_remount(ctx, root_disk, "ext4", NULL));
    for (unsigned i = 0; i < nshare; i++) {
        char *spec = strdup(shares[i]);
        char *path = strchr(spec, ':');
        if (!path) { fprintf(stderr, "--share needs TAG:HOSTPATH\n"); return 64; }
        *path++ = 0;
        CHECK(krun_add_virtiofs(ctx, spec, path));
    }
    // flags as in krunkit; the shm window is where the guest maps host-visible Vulkan memory
    CHECK(krun_set_gpu_options2(ctx, VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL, (uint64_t)vram << 20));
    static struct krun_display_backend backend = {
        .features = KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER,
        .vtable.basic_framebuffer = { .disable_scanout = display_disable, .configure_scanout = display_configure,
                                      .alloc_frame = display_alloc_frame, .present_frame = display_present },
    };
    if (disp_w) {
        CHECK(krun_add_display(ctx, disp_w, disp_h));
        CHECK(krun_set_display_backend(ctx, &backend, sizeof backend));
        CHECK(input_add_devices((uint32_t)ctx)); // virtio-input keyboard + absolute pointer (libkrun INPUT=1)
        // virtio-snd playback through CoreAudio (libkrun SND=1, host-patches/libkrun/0010); VM_SOUND=0 disables
        if (!getenv("VM_SOUND") || strcmp(getenv("VM_SOUND"), "0") != 0) CHECK(krun_set_snd_device(ctx, true));
    }
    if (slirp) { // virtio-net eth0 to libslirp in this process (own kernel has no TSI); no offloads: slirp
                 // wants complete, checksummed frames
        int fd = slirp_net_start();
        if (fd < 0) { fprintf(stderr, "vm-gpu: libslirp failed to start\n"); return 1; }
        static uint8_t mac[6] = { 0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee };
        CHECK(krun_add_net_unixstream(ctx, NULL, fd, mac, 0, 0));
    }
    if (!net) { // the implicit vsock hijacks guest INET sockets (TSI); without --net keep vsock but no TSI
        CHECK(krun_disable_implicit_vsock(ctx));
        CHECK(krun_add_vsock(ctx, 0));
    }
    CHECK(krun_set_workdir(ctx, "/"));
    CHECK(krun_set_exec(ctx, argv[optind + 1], (const char *const *)&argv[optind + 2], envs));

    if (!disp_w) return run_vm((void *)(uintptr_t)ctx) ? 1 : 0;
    // AppKit must own the main thread; the VM runs on its own thread
    @autoreleasepool {
        open_window(disp_w, disp_h);
        pthread_t vm;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8 << 20);
        pthread_create(&vm, &attr, run_vm, (void *)(uintptr_t)ctx);
        [NSApp run];
    }
    return 0;
}
