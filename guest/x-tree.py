"""Guest: print the X window tree (id, depth, visual, map state, geometry, name), or check given window ids.
Usage: python3 x-tree.py [0xWINDOW ...]   (DISPLAY must be set; libX11 via ctypes, the guest has no compiler)"""
import ctypes as c
import sys

x = c.CDLL('libX11.so.6')
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong


class Attrs(c.Structure):
    _fields_ = [('x', c.c_int), ('y', c.c_int), ('width', c.c_int), ('height', c.c_int), ('border_width', c.c_int),
                ('depth', c.c_int), ('visual', c.c_void_p), ('root', c.c_ulong), ('c_class', c.c_int),
                ('bit_gravity', c.c_int), ('win_gravity', c.c_int), ('backing_store', c.c_int),
                ('backing_planes', c.c_ulong), ('backing_pixel', c.c_ulong), ('save_under', c.c_int),
                ('colormap', c.c_ulong), ('map_installed', c.c_int), ('map_state', c.c_int),
                ('all_event_masks', c.c_long), ('your_event_mask', c.c_long), ('do_not_propagate_mask', c.c_long),
                ('override_redirect', c.c_int), ('screen', c.c_void_p)]


ERR = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)(lambda d, e: 0)
x.XSetErrorHandler(ERR)
x.XGetWindowAttributes.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(Attrs)]
x.XVisualIDFromVisual.argtypes = [c.c_void_p]
x.XVisualIDFromVisual.restype = c.c_ulong
x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_char_p)]
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                         c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
d = x.XOpenDisplay(None)


def describe(w, indent=''):
    a = Attrs()
    if not x.XGetWindowAttributes(d, w, c.byref(a)):
        print(f'{indent}{w:#x} gone')
        return False
    name = c.c_char_p()
    x.XFetchName(d, w, c.byref(name))
    state = ('unmapped', 'unviewable', 'viewable')[a.map_state]
    print(f'{indent}{w:#x} depth {a.depth} visual {x.XVisualIDFromVisual(a.visual):#x} {state} '
          f'{a.width}x{a.height}+{a.x}+{a.y} {name.value.decode(errors="replace") if name.value else ""}')
    return a.map_state == 2 or indent == ''


def tree(w, indent=''):
    if not describe(w, indent):
        return
    root, parent, children, n = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if x.XQueryTree(d, w, c.byref(root), c.byref(parent), c.byref(children), c.byref(n)):
        for i in range(n.value):
            tree(children[i], indent + '  ')


if len(sys.argv) > 1:
    for arg in sys.argv[1:]:
        describe(int(arg, 16))
else:
    tree(x.XDefaultRootWindow(d))
