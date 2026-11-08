// Host test: does the Vulkan driver (KosmicKrisp via the loader) meet DXVK's (D3D8/9/10/11) hard requirements?
// Source: DXVK v3.1.1 src/dxvk/dxvk_device_info.cpp getFeatureList() (entries with require = true),
// checkDeviceCompatibility() (Vulkan 1.3, >= 256 bytes push data without descriptor heaps).
// Build: cc -I/opt/homebrew/include -L/opt/homebrew/lib -lvulkan -o /tmp/dxvk-req dxvk-requirements.c
// Guest: gcc -o /out/x <file> -lvulkan (builder VM), run in the guest over Venus.
// Run:   VK_DRIVER_FILES=<icd.json> /tmp/dxvk-req
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int missing;

static void check(const char *what, int ok) {
    if (!ok) missing++;
    printf("%-4s %s\n", ok ? "ok" : "MISS", what);
}

int main(void) {
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
#ifdef __APPLE__ // macOS loader lists KosmicKrisp only as a portability driver; in the guest (Venus) not needed
    const char *iext[] = { VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME };
    ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, ici.enabledExtensionCount = 1;
    ici.ppEnabledExtensionNames = iext;
#endif
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) return puts("no instance"), 1;
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);

    VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    vkGetPhysicalDeviceProperties2(pd, &props);
    VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT clip = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, &xfb };
    VkPhysicalDeviceRobustness2FeaturesEXT rob = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT, &clip };
    VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &rob };
    VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13 };
    VkPhysicalDeviceVulkan11Features v11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12 };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11 };
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    VkPhysicalDeviceFeatures *c = &f2.features;

    uint32_t ne = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL);
    VkExtensionProperties *ext = calloc(ne, sizeof *ext);
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ext);
#define HAS(name) ({ int found = 0; for (uint32_t i = 0; i < ne; i++) found |= !strcmp(ext[i].extensionName, name); found; })

    printf("%s, Vulkan %u.%u\n", props.properties.deviceName, VK_API_VERSION_MAJOR(props.properties.apiVersion),
           VK_API_VERSION_MINOR(props.properties.apiVersion));
    check("Vulkan 1.3", props.properties.apiVersion >= VK_API_VERSION_1_3);
    check("push data >= 256 bytes", props.properties.limits.maxPushConstantsSize >= 256);
#define F(s, f) check(#f, s.f)
    F((*c), depthBiasClamp); F((*c), depthClamp); F((*c), dualSrcBlend); F((*c), fillModeNonSolid);
    F((*c), fragmentStoresAndAtomics); F((*c), fullDrawIndexUint32); F((*c), geometryShader); F((*c), imageCubeArray);
    F((*c), independentBlend); F((*c), multiDrawIndirect); F((*c), multiViewport); F((*c), occlusionQueryPrecise);
    F((*c), robustBufferAccess); F((*c), sampleRateShading); F((*c), samplerAnisotropy); F((*c), shaderClipDistance);
    F((*c), shaderCullDistance); F((*c), shaderImageGatherExtended); F((*c), shaderInt16); F((*c), shaderInt64);
    F((*c), shaderSampledImageArrayDynamicIndexing); F((*c), textureCompressionBC);
    F(v11, shaderDrawParameters); F(v11, storageBuffer16BitAccess);
    F(v12, bufferDeviceAddress); F(v12, descriptorIndexing); F(v12, storageBuffer8BitAccess);
    F(v12, descriptorBindingSampledImageUpdateAfterBind); F(v12, descriptorBindingUpdateUnusedWhilePending);
    F(v12, descriptorBindingPartiallyBound); F(v12, hostQueryReset); F(v12, runtimeDescriptorArray);
    F(v12, samplerMirrorClampToEdge); F(v12, scalarBlockLayout); F(v12, shaderInt8); F(v12, timelineSemaphore);
    F(v12, uniformBufferStandardLayout); F(v12, vulkanMemoryModel);
    F(v13, inlineUniformBlock); F(v13, computeFullSubgroups); F(v13, dynamicRendering); F(v13, maintenance4);
    F(v13, shaderDemoteToHelperInvocation); F(v13, shaderZeroInitializeWorkgroupMemory); F(v13, subgroupSizeControl);
    F(v13, synchronization2);
    check("VK_EXT_depth_clip_enable.depthClipEnable", HAS("VK_EXT_depth_clip_enable") && clip.depthClipEnable);
    check("robustness2.robustBufferAccess2", rob.robustBufferAccess2);
    check("robustness2.nullDescriptor", rob.nullDescriptor);
    check("VK_KHR_load_store_op_none", HAS("VK_KHR_load_store_op_none") || HAS("VK_EXT_load_store_op_none") ||
                                           props.properties.apiVersion >= VK_API_VERSION_1_4);
    check("VK_KHR_maintenance5", HAS("VK_KHR_maintenance5"));
    check("VK_KHR_maintenance6", HAS("VK_KHR_maintenance6"));
    check("VK_KHR_swapchain", HAS("VK_KHR_swapchain"));
    printf("optional (some games): transformFeedback %u, geometryStreams %u, tessellationShader %u\n",
           xfb.transformFeedback, xfb.geometryStreams, c->tessellationShader);
    printf("%d required feature(s) missing\n", missing);
    return missing != 0;
}
