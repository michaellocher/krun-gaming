#!/bin/bash
# Runs inside the guest (launcher --display): gbm-export-test.py on the card node, default driver and zink. On the zink
# run VN_DEBUG=result logs every failing Venus call (which Vulkan call breaks the export).
mkdir -p /out && mount -t virtiofs out /out
{
  python3 /spike/gbm-export-test.py /dev/dri/card0
  MESA_LOADER_DRIVER_OVERRIDE=zink VN_DEBUG=result LIBGL_DEBUG=verbose MESA_DEBUG=1 MESA_LOG_LEVEL=debug python3 /spike/gbm-export-test.py /dev/dri/card0
} > /out/gbm-export.txt 2>&1
