// Keyboard and pointer for the guest: the window's view turns AppKit events into Linux input events (evdev codes),
// queued per device and handed to libkrun's virtio-input through krun_add_input_device. The pointer is absolute
// (tablet-like, 0..32767 on both axes), so the guest cursor follows the Mac cursor without capture.
#import "input-mac.h"

#include <fcntl.h>
#include <libkrun.h>
#include <libkrun_input.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

enum { EV_SYN = 0, EV_KEY = 1, EV_REL = 2, EV_ABS = 3, SYN_REPORT = 0 };
enum { ABS_X = 0, ABS_Y = 1, ABS_MAX_VALUE = 32767, REL_HWHEEL = 6, REL_WHEEL = 8 };
enum { BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, INPUT_PROP_POINTER = 0, BUS_VIRTUAL = 6 };
enum { QUEUE = 1024 };

struct device {
    const char *name;
    pthread_mutex_t lock;
    struct krun_input_event q[QUEUE];
    unsigned head, tail; // head == tail: empty
    int pipe_fd[2];      // read end is the "ready" fd: readable while events are queued
};

static struct device keyboard = { .name = "krun-gaming keyboard", .lock = PTHREAD_MUTEX_INITIALIZER };
static struct device pointer = { .name = "krun-gaming pointer", .lock = PTHREAD_MUTEX_INITIALIZER };

static void push(struct device *d, uint16_t type, uint16_t code, int32_t value) {
    pthread_mutex_lock(&d->lock);
    unsigned next = (d->tail + 1) % QUEUE;
    if (next != d->head) { // full: drop (the guest is not reading)
        d->q[d->tail] = (struct krun_input_event){ type, code, (uint32_t)value };
        d->tail = next;
    }
    pthread_mutex_unlock(&d->lock);
}

static void report(struct device *d) {
    push(d, EV_SYN, SYN_REPORT, 0);
    (void)!write(d->pipe_fd[1], "", 1);
}

// ---- event provider (called on libkrun's input worker thread) ----

static int32_t create(void **instance, const void *userdata, const void *reserved) {
    (void)reserved;
    *instance = (void *)userdata;
    return 0;
}

static int ready_fd(void *instance) { return ((struct device *)instance)->pipe_fd[0]; }

static int32_t next_event(void *instance, struct krun_input_event *out) {
    struct device *d = instance;
    pthread_mutex_lock(&d->lock);
    int32_t got = d->head != d->tail;
    if (got) {
        *out = d->q[d->head];
        d->head = (d->head + 1) % QUEUE;
    } else { // drained: make the ready fd non-readable again, or libkrun's worker spins
        char buf[256];
        while (read(d->pipe_fd[0], buf, sizeof buf) > 0) {}
    }
    pthread_mutex_unlock(&d->lock);
    return got;
}

// ---- device description ----

static void set_bit(uint8_t *bm, unsigned bit) { bm[bit / 8] |= (uint8_t)(1u << (bit % 8)); }

static int32_t query_name(void *instance, uint8_t *buf, size_t len) {
    const char *name = ((struct device *)instance)->name;
    size_t n = strlen(name) < len ? strlen(name) : len;
    memcpy(buf, name, n);
    return (int32_t)n;
}

static int32_t query_serial(void *instance, uint8_t *buf, size_t len) { (void)instance; (void)buf; (void)len; return 0; }

static int32_t query_ids(void *instance, struct krun_input_device_ids *ids) {
    *ids = (struct krun_input_device_ids){ .bustype = BUS_VIRTUAL, .vendor = 0x4b47,
                                           .product = instance == &keyboard ? 1 : 2, .version = 1 };
    return 0;
}

static int32_t query_caps(void *instance, uint8_t type, uint8_t *bm, size_t len) {
    memset(bm, 0, len);
    unsigned top = 0; // highest bit set + 1
    if (instance == &keyboard && type == EV_KEY) {
        for (unsigned k = 1; k < 248; k++) set_bit(bm, k);
        top = 248;
    } else if (instance == &pointer && type == EV_KEY) {
        set_bit(bm, BTN_LEFT), set_bit(bm, BTN_RIGHT), set_bit(bm, BTN_MIDDLE);
        top = BTN_MIDDLE + 1;
    } else if (instance == &pointer && type == EV_ABS) {
        set_bit(bm, ABS_X), set_bit(bm, ABS_Y);
        top = ABS_Y + 1;
    } else if (instance == &pointer && type == EV_REL) {
        set_bit(bm, REL_HWHEEL), set_bit(bm, REL_WHEEL);
        top = REL_WHEEL + 1;
    }
    size_t n = (top + 7) / 8;
    return (int32_t)(n < len ? n : len);
}

static int32_t query_abs(void *instance, uint8_t axis, struct krun_input_absinfo *info) {
    if (instance != &pointer || axis > ABS_Y) return KRUN_INPUT_ERR_INVALID_PARAM;
    *info = (struct krun_input_absinfo){ .min = 0, .max = ABS_MAX_VALUE };
    return 0;
}

static int32_t query_props(void *instance, uint8_t *bm, size_t len) {
    memset(bm, 0, len);
    if (instance != &pointer) return 0;
    set_bit(bm, INPUT_PROP_POINTER);
    return 1;
}

static int add_device(uint32_t ctx, struct device *d) {
    if (pipe(d->pipe_fd) != 0) return -1;
    fcntl(d->pipe_fd[0], F_SETFL, O_NONBLOCK);
    fcntl(d->pipe_fd[1], F_SETFL, O_NONBLOCK);
    struct krun_input_config config = {
        .features = KRUN_INPUT_CONFIG_FEATURE_QUERY, .create_userdata = d, .create = create,
        .vtable = { .query_device_name = query_name, .query_serial_name = query_serial,
                    .query_device_ids = query_ids, .query_event_capabilities = query_caps,
                    .query_abs_info = query_abs, .query_properties = query_props },
    };
    struct krun_input_event_provider events = {
        .features = KRUN_INPUT_EVENT_PROVIDER_FEATURE_QUEUE, .create_userdata = d, .create = create,
        .vtable = { .get_ready_efd = ready_fd, .next_event = next_event },
    };
    return krun_add_input_device(ctx, &config, sizeof config, &events, sizeof events);
}

int input_add_devices(uint32_t ctx) {
    int r = add_device(ctx, &keyboard);
    return r < 0 ? r : add_device(ctx, &pointer);
}

// ---- macOS virtual keycodes (Carbon kVK_*) to Linux KEY_* ----

static const uint16_t keymap[128] = {
    [0x00] = 30, [0x01] = 31, [0x02] = 32, [0x03] = 33, [0x04] = 35, [0x05] = 34, [0x06] = 44, [0x07] = 45, // A S D F H G Z X
    [0x08] = 46, [0x09] = 47, [0x0A] = 86, [0x0B] = 48, [0x0C] = 16, [0x0D] = 17, [0x0E] = 18, [0x0F] = 19, // C V § B Q W E R
    [0x10] = 21, [0x11] = 20, [0x12] = 2, [0x13] = 3, [0x14] = 4, [0x15] = 5, [0x16] = 7, [0x17] = 6,      // Y T 1 2 3 4 6 5
    [0x18] = 13, [0x19] = 10, [0x1A] = 8, [0x1B] = 12, [0x1C] = 9, [0x1D] = 11, [0x1E] = 27, [0x1F] = 24,  // = 9 7 - 8 0 ] O
    [0x20] = 22, [0x21] = 26, [0x22] = 23, [0x23] = 25, [0x24] = 28, [0x25] = 38, [0x26] = 36, [0x27] = 40, // U [ I P ⏎ L J '
    [0x28] = 37, [0x29] = 39, [0x2A] = 43, [0x2B] = 51, [0x2C] = 53, [0x2D] = 49, [0x2E] = 50, [0x2F] = 52, // K ; \ , / N M .
    [0x30] = 15, [0x31] = 57, [0x32] = 41, [0x33] = 14, [0x35] = 1,                                         // tab space ` ⌫ esc
    [0x36] = 126, [0x37] = 125, [0x38] = 42, [0x39] = 58, [0x3A] = 56, [0x3B] = 29, [0x3C] = 54,          // rcmd cmd shift caps alt ctrl rshift
    [0x3D] = 100, [0x3E] = 97,                                                                              // ralt rctrl
    [0x41] = 83, [0x43] = 55, [0x45] = 78, [0x4B] = 98, [0x4C] = 96, [0x4E] = 74, [0x51] = 117,             // keypad . * + / ⏎ - =
    [0x52] = 82, [0x53] = 79, [0x54] = 80, [0x55] = 81, [0x56] = 75, [0x57] = 76, [0x58] = 77, [0x59] = 71, // keypad 0-7
    [0x5B] = 72, [0x5C] = 73,                                                                               // keypad 8 9
    [0x60] = 63, [0x61] = 64, [0x62] = 65, [0x63] = 61, [0x64] = 66, [0x65] = 67, [0x67] = 87, [0x6D] = 68, // F5 F6 F7 F3 F8 F9 F11 F10
    [0x6F] = 88, [0x72] = 110, [0x73] = 102, [0x74] = 104, [0x75] = 111, [0x76] = 62, [0x77] = 107,         // F12 ins home pgup del F4 end
    [0x78] = 60, [0x79] = 109, [0x7A] = 59, [0x7B] = 105, [0x7C] = 106, [0x7D] = 108, [0x7E] = 103,         // F2 pgdn F1 ← → ↓ ↑
};

@implementation InputView {
    bool modifier_down[128];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

// the guest (gamescope) draws its own cursor at the same spot: hide the Mac one over the view
- (void)resetCursorRects {
    static NSCursor *blank;
    if (!blank) blank = [[NSCursor alloc] initWithImage:[[NSImage alloc] initWithSize:NSMakeSize(1, 1)]
                                                hotSpot:NSZeroPoint];
    [self addCursorRect:self.bounds cursor:blank];
}

- (void)key:(NSEvent *)e down:(bool)down {
    uint16_t code = e.keyCode < 128 ? keymap[e.keyCode] : 0;
    if (!code || (down && e.isARepeat)) return; // the guest does its own key repeat
    push(&keyboard, EV_KEY, code, down);
    report(&keyboard);
}
- (void)keyDown:(NSEvent *)e { [self key:e down:true]; }
- (void)keyUp:(NSEvent *)e { [self key:e down:false]; }
- (void)flagsChanged:(NSEvent *)e { // modifiers: each change toggles the key that caused it
    if (e.keyCode >= 128 || !keymap[e.keyCode]) return;
    modifier_down[e.keyCode] = !modifier_down[e.keyCode];
    [self key:e down:modifier_down[e.keyCode]];
}

- (void)move:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSSize s = self.bounds.size;
    if (s.width <= 0 || s.height <= 0) return;
    double x = p.x / s.width, y = 1.0 - p.y / s.height; // AppKit's origin is bottom left
    x = x < 0 ? 0 : x > 1 ? 1 : x, y = y < 0 ? 0 : y > 1 ? 1 : y;
    push(&pointer, EV_ABS, ABS_X, (int32_t)(x * ABS_MAX_VALUE));
    push(&pointer, EV_ABS, ABS_Y, (int32_t)(y * ABS_MAX_VALUE));
    report(&pointer);
}
- (void)button:(uint16_t)btn event:(NSEvent *)e down:(bool)down {
    [self move:e];
    push(&pointer, EV_KEY, btn, down);
    report(&pointer);
}
- (void)mouseMoved:(NSEvent *)e { [self move:e]; }
- (void)mouseDragged:(NSEvent *)e { [self move:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self move:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self move:e]; }
- (void)mouseDown:(NSEvent *)e { [self button:BTN_LEFT event:e down:true]; }
- (void)mouseUp:(NSEvent *)e { [self button:BTN_LEFT event:e down:false]; }
- (void)rightMouseDown:(NSEvent *)e { [self button:BTN_RIGHT event:e down:true]; }
- (void)rightMouseUp:(NSEvent *)e { [self button:BTN_RIGHT event:e down:false]; }
- (void)otherMouseDown:(NSEvent *)e { [self button:BTN_MIDDLE event:e down:true]; }
- (void)otherMouseUp:(NSEvent *)e { [self button:BTN_MIDDLE event:e down:false]; }
- (void)scrollWheel:(NSEvent *)e {
    int dy = (int)e.scrollingDeltaY, dx = (int)e.scrollingDeltaX;
    if (e.hasPreciseScrollingDeltas) dy /= 10, dx /= 10; // trackpad pixels to wheel clicks
    if (dy) push(&pointer, EV_REL, REL_WHEEL, dy);
    if (dx) push(&pointer, EV_REL, REL_HWHEEL, -dx);
    if (dx || dy) report(&pointer);
}
@end
