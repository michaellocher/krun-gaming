// Guest test: read an X window's contents from the X server (XGetImage) and write a PPM, plus the window's depth and
// visual — tells whether a black screen is the client's output (black in the server) or the compositor's.
// Usage: xgrab <window id, decimal or 0x hex> <out.ppm>. Build (builder VM): gcc -O2 -o xgrab xgrab.c -lX11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) return puts("usage: xgrab <window> <out.ppm>"), 2;
    Display *d = XOpenDisplay(NULL);
    if (!d) return puts("no display"), 1;
    Window win = (Window)strtoul(argv[1], NULL, 0);
    XWindowAttributes wa;
    if (!XGetWindowAttributes(d, win, &wa)) return puts("bad window"), 1;
    printf("window 0x%lx %dx%d+%d+%d depth %d visual 0x%lx map_state %d\n", win, wa.width, wa.height, wa.x, wa.y,
           wa.depth, XVisualIDFromVisual(wa.visual), wa.map_state);
    Window root, parent, *children;
    unsigned n;
    if (XQueryTree(d, win, &root, &parent, &children, &n)) {
        for (unsigned i = 0; i < n; i++) {
            XWindowAttributes ca;
            XGetWindowAttributes(d, children[i], &ca);
            printf("  child 0x%lx %dx%d+%d+%d depth %d visual 0x%lx map_state %d\n", children[i], ca.width,
                   ca.height, ca.x, ca.y, ca.depth, XVisualIDFromVisual(ca.visual), ca.map_state);
        }
    }
    XImage *img = XGetImage(d, win, 0, 0, wa.width, wa.height, AllPlanes, ZPixmap);
    if (!img) return puts("XGetImage failed"), 1;
    FILE *f = fopen(argv[2], "wb");
    fprintf(f, "P6\n%d %d\n255\n", wa.width, wa.height);
    unsigned long lit = 0, alpha_hist[5] = { 0 }; // alpha 0, 1-63, 64-191, 192-254, 255
    for (int y = 0; y < wa.height; y++)
        for (int x = 0; x < wa.width; x++) {
            unsigned long p = XGetPixel(img, x, y);
            lit += (p & 0xffffff) != 0;
            unsigned a = (p >> 24) & 0xff;
            alpha_hist[a == 0 ? 0 : a < 64 ? 1 : a < 192 ? 2 : a < 255 ? 3 : 4]++;
            fputc((p >> 16) & 0xff, f), fputc((p >> 8) & 0xff, f), fputc(p & 0xff, f);
        }
    fclose(f);
    printf("lit pixels: %lu of %d\n", lit, wa.width * wa.height);
    if (wa.depth == 32)
        printf("alpha: 0: %lu, 1-63: %lu, 64-191: %lu, 192-254: %lu, 255: %lu\n", alpha_hist[0], alpha_hist[1],
               alpha_hist[2], alpha_hist[3], alpha_hist[4]);
    return 0;
}
