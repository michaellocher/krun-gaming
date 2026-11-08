// Guest experiment: copy a window's composited contents (children included) onto itself RATE times per second, so
// the X server records damage on the top-level window. Tests whether updates of an automatically redirected child
// window (different visual than its parent) reach the Wayland compositor only when the parent is damaged.
// Usage: xpump <window> [rate, default 30] [seconds, default 0 = forever]. Build: gcc -O2 -o xpump xpump.c -lX11
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return puts("usage: xpump <window> [rate] [seconds]"), 2;
    Display *d = XOpenDisplay(NULL);
    if (!d) return puts("no display"), 1;
    Window win = (Window)strtoul(argv[1], NULL, 0);
    int rate = argc > 2 ? atoi(argv[2]) : 30, seconds = argc > 3 ? atoi(argv[3]) : 0;
    XWindowAttributes wa;
    if (!XGetWindowAttributes(d, win, &wa)) return puts("bad window"), 1;
    XGCValues v = { .subwindow_mode = IncludeInferiors, .graphics_exposures = False };
    GC gc = XCreateGC(d, win, GCSubwindowMode | GCGraphicsExposures, &v);
    for (long t = 0; seconds == 0 || t < (long)seconds * rate; t++) {
        XCopyArea(d, win, win, gc, 0, 0, wa.width, wa.height, 0, 0);
        XFlush(d);
        usleep(1000000 / rate);
    }
    return 0;
}
