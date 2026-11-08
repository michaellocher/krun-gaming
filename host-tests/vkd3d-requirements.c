// Host test: does the Vulkan driver (KosmicKrisp via the loader) meet vkd3d-proton's (DX12) requirements?
// Required per the vkd3d-proton README: Vulkan 1.3, all VkPhysicalDeviceDescriptorIndexingFeatures, >= 1000000
// UpdateAfterBind descriptors (all types but uniform buffers), samplerMirrorClampToEdge, shaderDrawParameters,
// VK_EXT_robustness2, VK_KHR_push_descriptor. Recommended: mutable_descriptor_type, descriptor_buffer, image_view_min_lod.
// Build: cc -I/opt/homebrew/include -L/opt/homebrew/lib -lvulkan -o /tmp/vkd3d-req vkd3d-requirements.c
// Guest: gcc -o /out/x <file> -lvulkan (builder VM), run in the guest over Venus.
// Run:   VK_DRIVER_FILES=<icd.json> /tmp/vkd3d-req
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int has_ext(VkExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(e[i].extensionName, name)) return 1;
    return 0;
}

static void check(const char *what, int ok) { printf("%-4s %s\n", ok ? "ok" : "MISS", what); }

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

    VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
    VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p12 };
    vkGetPhysicalDeviceProperties2(pd, &props);
    uint32_t v = props.properties.apiVersion;
    printf("%s, Vulkan %u.%u.%u\n", props.properties.deviceName, VK_API_VERSION_MAJOR(v), VK_API_VERSION_MINOR(v),
           VK_API_VERSION_PATCH(v));

    VkPhysicalDeviceRobustness2FeaturesEXT rob = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    VkPhysicalDeviceVulkan12Features f12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &rob };
    VkPhysicalDeviceVulkan11Features f11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12 };
    VkPhysicalDeviceFeatures2 feats = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11 };
    vkGetPhysicalDeviceFeatures2(pd, &feats);

    uint32_t ne = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL);
    VkExtensionProperties *ext = calloc(ne, sizeof *ext);
    vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ext);

    check("Vulkan 1.3", v >= VK_API_VERSION_1_3);
    check("samplerMirrorClampToEdge", f12.samplerMirrorClampToEdge);
    check("shaderDrawParameters", f11.shaderDrawParameters);
    check("VK_EXT_robustness2", has_ext(ext, ne, "VK_EXT_robustness2") || has_ext(ext, ne, "VK_KHR_robustness2"));
    printf("     robustBufferAccess2 %u robustImageAccess2 %u nullDescriptor %u\n", rob.robustBufferAccess2,
           rob.robustImageAccess2, rob.nullDescriptor);
    check("VK_KHR_push_descriptor", has_ext(ext, ne, "VK_KHR_push_descriptor"));
#define DI(f) check("descriptorIndexing." #f, f12.f)
    DI(shaderInputAttachmentArrayDynamicIndexing); DI(shaderUniformTexelBufferArrayDynamicIndexing);
    DI(shaderStorageTexelBufferArrayDynamicIndexing); DI(shaderUniformBufferArrayNonUniformIndexing);
    DI(shaderSampledImageArrayNonUniformIndexing); DI(shaderStorageBufferArrayNonUniformIndexing);
    DI(shaderStorageImageArrayNonUniformIndexing); DI(shaderInputAttachmentArrayNonUniformIndexing);
    DI(shaderUniformTexelBufferArrayNonUniformIndexing); DI(shaderStorageTexelBufferArrayNonUniformIndexing);
    DI(descriptorBindingUniformBufferUpdateAfterBind); DI(descriptorBindingSampledImageUpdateAfterBind);
    DI(descriptorBindingStorageImageUpdateAfterBind); DI(descriptorBindingStorageBufferUpdateAfterBind);
    DI(descriptorBindingUniformTexelBufferUpdateAfterBind); DI(descriptorBindingStorageTexelBufferUpdateAfterBind);
    DI(descriptorBindingUpdateUnusedWhilePending); DI(descriptorBindingPartiallyBound);
    DI(descriptorBindingVariableDescriptorCount); DI(runtimeDescriptorArray);
#define UAB(f) printf("%-4s %s = %u\n", p12.f >= 1000000 ? "ok" : "MISS", #f, p12.f)
    UAB(maxDescriptorSetUpdateAfterBindSamplers); UAB(maxDescriptorSetUpdateAfterBindSampledImages);
    UAB(maxDescriptorSetUpdateAfterBindStorageImages); UAB(maxDescriptorSetUpdateAfterBindStorageBuffers);
    UAB(maxPerStageDescriptorUpdateAfterBindSampledImages); UAB(maxPerStageDescriptorUpdateAfterBindStorageImages);
    // hard checks in vkd3d-proton v3.1 libs/vkd3d/device.c vkd3d_init_device_caps (not all listed in the README)
    VkPhysicalDeviceVulkan13Properties p13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES };
    VkPhysicalDeviceProperties2 props13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p13 };
    vkGetPhysicalDeviceProperties2(pd, &props13);
    puts("vkd3d-proton device.c hard checks:");
    check("VK_EXT_transform_feedback (transformFeedbackQueries)", has_ext(ext, ne, "VK_EXT_transform_feedback"));
    check("VK_EXT/KHR_vertex_attribute_divisor", has_ext(ext, ne, "VK_EXT_vertex_attribute_divisor") ||
                                                    has_ext(ext, ne, "VK_KHR_vertex_attribute_divisor"));
    check("single texel alignment (storage)", p13.storageTexelBufferOffsetSingleTexelAlignment ||
                                                  p13.storageTexelBufferOffsetAlignmentBytes == 1);
    check("single texel alignment (uniform)", p13.uniformTexelBufferOffsetSingleTexelAlignment ||
                                                  p13.uniformTexelBufferOffsetAlignmentBytes == 1);
    check("VK_KHR_maintenance5", has_ext(ext, ne, "VK_KHR_maintenance5"));
    check("VK_KHR_maintenance6", has_ext(ext, ne, "VK_KHR_maintenance6"));
    check("VK_EXT_dynamic_rendering_unused_attachments (warned as required)",
          has_ext(ext, ne, "VK_EXT_dynamic_rendering_unused_attachments"));
    puts("D3D feature level 11_0 shader stages:");
    check("geometryShader", feats.features.geometryShader);
    check("tessellationShader", feats.features.tessellationShader);
    puts("recommended:");
    check("VK_EXT_mutable_descriptor_type", has_ext(ext, ne, "VK_EXT_mutable_descriptor_type") ||
                                                has_ext(ext, ne, "VK_VALVE_mutable_descriptor_type"));
    check("VK_EXT_descriptor_buffer", has_ext(ext, ne, "VK_EXT_descriptor_buffer"));
    check("VK_EXT_image_view_min_lod", has_ext(ext, ne, "VK_EXT_image_view_min_lod"));
    return 0;
}
