/* Can Venus export images? Queries vkGetPhysicalDeviceImageFormatProperties2 for typical shared-texture
 * formats (DXVK/Wine D3D11 shared resources, Media Foundation video) with the external handle types Wine
 * uses on the host (OPAQUE_FD first, then DMA_BUF) and prints the external memory features.
 * Build: gcc -O2 -o external-image external-image.c -lvulkan (guest/req-build.sh) */
#include <stdio.h>
#include <vulkan/vulkan.h>

static void query(VkPhysicalDevice pd, VkFormat format, const char *name, VkExternalMemoryHandleTypeFlagBits type,
                  const char *type_name, VkImageUsageFlags usage)
{
    VkPhysicalDeviceExternalImageFormatInfo ext = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO, .handleType = type};
    VkPhysicalDeviceImageFormatInfo2 info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = &ext, .format = format,
        .type = VK_IMAGE_TYPE_2D, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage};
    VkExternalImageFormatProperties ext_props = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};
    VkImageFormatProperties2 props = {.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &ext_props};
    VkResult r = vkGetPhysicalDeviceImageFormatProperties2(pd, &info, &props);
    VkExternalMemoryFeatureFlags f = ext_props.externalMemoryProperties.externalMemoryFeatures;
    printf("%-10s %-8s usage %#05x: result %d, features%s%s%s\n", name, type_name, usage, r,
           f & VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT ? " dedicated-only" : "",
           f & VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT ? " exportable" : "",
           f & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT ? " importable" : "");
}

int main(void)
{
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) return 1;
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (!n) return 1;

    const VkImageUsageFlags sampled = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                      VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const VkImageUsageFlags target = sampled | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    struct { VkFormat f; const char *n; } formats[] = {
        {VK_FORMAT_B8G8R8A8_UNORM, "BGRA8"},
        {VK_FORMAT_R8G8B8A8_UNORM, "RGBA8"},
        {VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, "NV12"},
    };
    for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        query(pd, formats[i].f, formats[i].n, VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT, "opaque", sampled);
        query(pd, formats[i].f, formats[i].n, VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT, "opaque", target);
        query(pd, formats[i].f, formats[i].n, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, "dma_buf", sampled);
        query(pd, formats[i].f, formats[i].n, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, "dma_buf", target);
    }
    vkDestroyInstance(inst, NULL);
    return 0;
}
