// Guest test: draw a solid bar into an existing X window (any client may) for SECONDS — shows whether drawing into
// that window reaches the compositor (e.g. a top-level vs. a child window owned by another client).
// Usage: xdraw <window> <0xRRGGBB> <y> [seconds]. Build (builder VM): gcc -O2 -o xdraw xdraw.c -lX11
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) return puts("usage: xdraw <window> <0xRRGGBB> <y> [seconds]"), 2;
    Display *d = XOpenDisplay(NULL);
    if (!d) return puts("no display"), 1;
    Window win = (Window)strtoul(argv[1], NULL, 0);
    unsigned long color = strtoul(argv[2], NULL, 0) | 0xff000000ul; // opaque in 32-bit visuals
    int y = atoi(argv[3]), seconds = argc > 4 ? atoi(argv[4]) : 6;
    GC gc = XCreateGC(d, win, 0, NULL);
    XSetForeground(d, gc, color);
    for (int t = 0; t < seconds * 10; t++) {
        XFillRectangle(d, win, gc, 0, y, 1280, 60);
        XFlush(d);
        usleep(100000);
    }
    printf("xdraw: drew 0x%06lx at y=%d into 0x%lx\n", color & 0xffffff, y, win);
    return 0;
}
