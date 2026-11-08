#!/bin/sh
# Runs inside the guest: Venus device, API version and the WSI-relevant extensions.
vulkaninfo --summary 2>/dev/null | grep -E 'apiVersion|deviceName' | head -2
vulkaninfo 2>/dev/null > /tmp/vi.txt
n=$(grep -n '^Device Extensions' /tmp/vi.txt | head -1 | cut -d: -f1)
sed -n "${n},\$p" /tmp/vi.txt | awk 'NR>1 && /^$/{exit} {print}' | grep -o -E 'VK_KHR_swapchain|VK_EXT_external_memory_dma_buf|VK_KHR_external_memory_fd|VK_EXT_image_drm_format_modifier|VK_KHR_external_fence_fd' | sort -u
grep -m1 '^Device Extensions' /tmp/vi.txt
