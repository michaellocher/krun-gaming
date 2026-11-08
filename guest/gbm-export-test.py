#!/usr/bin/env python3
# Runs inside the guest: allocate gbm buffers (as Xwayland/glamor and Chromium do) and export them as dma-buf.
# Run with MESA_LOADER_DRIVER_OVERRIDE=zink to test gbm on zink, without it for the virtio-gpu default.
import ctypes
import os
import sys

gbm = ctypes.CDLL('libgbm.so.1', use_errno=True)
gbm.gbm_create_device.restype = ctypes.c_void_p
gbm.gbm_create_device.argtypes = [ctypes.c_int]
gbm.gbm_device_get_backend_name.restype = ctypes.c_char_p
gbm.gbm_device_get_backend_name.argtypes = [ctypes.c_void_p]
gbm.gbm_bo_create.restype = ctypes.c_void_p
gbm.gbm_bo_create.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32]
gbm.gbm_bo_create_with_modifiers2.restype = ctypes.c_void_p
gbm.gbm_bo_create_with_modifiers2.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
                                              ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint, ctypes.c_uint32]
gbm.gbm_bo_get_fd.argtypes = [ctypes.c_void_p]
gbm.gbm_bo_get_modifier.restype = ctypes.c_uint64
gbm.gbm_bo_get_modifier.argtypes = [ctypes.c_void_p]

XRGB8888 = 0x34325258
SCANOUT, RENDERING, LINEAR = 1 << 0, 1 << 2, 1 << 4
node = sys.argv[1] if len(sys.argv) > 1 else '/dev/dri/renderD128'
dev = gbm.gbm_create_device(os.open(node, os.O_RDWR))
print(f'{node} override={os.environ.get("MESA_LOADER_DRIVER_OVERRIDE", "-")} '
      f'backend={gbm.gbm_device_get_backend_name(dev).decode()}')


def report(name, bo):
    if not bo:
        print(f'  {name}: create failed errno={ctypes.get_errno()}')
        return
    fd = gbm.gbm_bo_get_fd(bo)
    err = os.strerror(ctypes.get_errno()) if fd < 0 else 'ok'
    print(f'  {name}: modifier={gbm.gbm_bo_get_modifier(bo):#x} export fd={fd} ({err})')


for name, flags in [('RENDERING', RENDERING), ('RENDERING|SCANOUT', RENDERING | SCANOUT),
                    ('RENDERING|LINEAR', RENDERING | LINEAR)]:
    report(name, gbm.gbm_bo_create(dev, 1280, 720, XRGB8888, flags))
mods = (ctypes.c_uint64 * 1)(0)  # DRM_FORMAT_MOD_LINEAR, what the virtio-gpu plane advertises
report('modifiers [LINEAR]', gbm.gbm_bo_create_with_modifiers2(dev, 1280, 720, XRGB8888, mods, 1, RENDERING))
