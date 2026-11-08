// Guest test: an X11 window like Steam's (32-bit ARGB visual) filled with orange at alpha ALPHA (argv[1], default
// 255) for SECONDS (argv[2], default 8). Shows whether gamescope composites ARGB windows and how it treats alpha.
// Build (builder VM): gcc -O2 -o argb-window argb-window.c -lX11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    unsigned alpha = argc > 1 ? (unsigned)atoi(argv[1]) : 255, seconds = argc > 2 ? (unsigned)atoi(argv[2]) : 8;
    Display *d = XOpenDisplay(NULL);
    if (!d) return puts("no display"), 1;
    XVisualInfo vi;
    if (!XMatchVisualInfo(d, DefaultScreen(d), 32, TrueColor, &vi)) return puts("no 32-bit visual"), 1;
    XSetWindowAttributes a = { .colormap = XCreateColormap(d, DefaultRootWindow(d), vi.visual, AllocNone),
                               .border_pixel = 0, .background_pixel = 0 };
    unsigned w = 1280, h = 720;
    Window win = XCreateWindow(d, DefaultRootWindow(d), 0, 0, w, h, 0, 32, InputOutput, vi.visual,
                               CWColormap | CWBorderPixel | CWBackPixel, &a);
    XStoreName(d, win, "argb-window");
    XMapWindow(d, win);
    GC gc = XCreateGC(d, win, 0, NULL);
    unsigned long pixel = ((unsigned long)alpha << 24) | 0xff8000; // orange, premultiplication ignored on purpose
    printf("argb-window: visual 0x%lx depth 32, alpha %u\n", vi.visualid, alpha);
    for (unsigned t = 0; t < seconds * 10; t++) {
        XSetForeground(d, gc, pixel);
        XFillRectangle(d, win, gc, 0, 0, w, h);
        XFlush(d);
        usleep(100000);
    }
    return 0;
}
