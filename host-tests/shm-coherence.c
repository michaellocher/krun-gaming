// Host test: do GPU writes into a linear image bound to imported host memory (as virglrenderer's Venus does on macOS:
// anonymous file -> mmap MAP_SHARED -> VK_EXT_external_memory_host) show up in a second mapping of the same file
// (as libkrun reads scanouts)? Clears the image to a new colour N times and reads both mappings after each.
// Mode `alias`: also import a second mapping of the same file (an exported buffer imported again, as virgl does
// for cross-context dma-bufs) and write through that one.
// Modes `copy` / `blit`: clear an optimal image, then vkCmdCopyImage / vkCmdBlitImage it into the linear one.
// Mode `compute <store.spv>`: write through a compute shader into an rgba8 storage view (gamescope's compositing).
// Build: cc -I/opt/homebrew/include -L/opt/homebrew/lib -lvulkan -o /tmp/shm-coherence shm-coherence.c
// Run:   VK_DRIVER_FILES=<icd.json> /tmp/shm-coherence
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define W 256
#define H 256
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("%s -> %d\n", #x, r_); return 1; } } while (0)

int main(int argc, char **argv) {
    const int compute = argc > 2 && !strcmp(argv[1], "compute");
    const int copy = argc > 1 && !strcmp(argv[1], "copy"), blit = argc > 1 && !strcmp(argv[1], "blit");
    const int alias = argc > 1 && !strcmp(argv[1], "alias");
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
#ifdef __APPLE__
    const char *iext[] = { VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME };
    ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, ici.enabledExtensionCount = 1;
    ici.ppEnabledExtensionNames = iext;
#endif
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);
    float prio = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
    const char *dext[] = { "VK_EXT_external_memory_host" };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                               .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    // memory as virglrenderer allocates it: an anonymous file, mapped shared
    size_t page = (size_t)getpagesize(), size = ((size_t)W * H * 4 + page - 1) & ~(page - 1);
    char path[] = "/tmp/shm-coherence-XXXXXX";
    int fd = mkstemp(path);
    unlink(path);
    if (fd < 0 || ftruncate(fd, (off_t)size) != 0) return puts("file"), 1;
    uint8_t *gpu_map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);   // handed to the driver
    uint8_t *reader = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);    // what libkrun reads
    if (gpu_map == MAP_FAILED || reader == MAP_FAILED) return puts("mmap"), 1;

    PFN_vkGetMemoryHostPointerPropertiesEXT get_props =
        (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
    VkMemoryHostPointerPropertiesEXT hp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
    CHECK(get_props(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, gpu_map, &hp));
    uint32_t type = (uint32_t)__builtin_ctz(hp.memoryTypeBits);

    VkExternalMemoryImageCreateInfo ext = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
                                            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
    VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &ext, VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, VK_IMAGE_TYPE_2D, VK_FORMAT_B8G8R8A8_UNORM,
                             { W, H, 1 }, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_LINEAR,
                             VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_SHARING_MODE_EXCLUSIVE,
                             0, NULL, VK_IMAGE_LAYOUT_UNDEFINED };
    VkImage img;
    CHECK(vkCreateImage(dev, &ii, NULL, &img));
    VkImportMemoryHostPointerInfoEXT imp = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                             VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, gpu_map };
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp, size, type };
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &ai, NULL, &mem));
    CHECK(vkBindImageMemory(dev, img, mem, 0));

    // alias: a second import of the same pages through another mapping; the clears below go to this image
    if (alias) {
        uint8_t *map2 = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        VkImage img2;
        CHECK(vkCreateImage(dev, &ii, NULL, &img2));
        VkImportMemoryHostPointerInfoEXT imp2 = imp;
        imp2.pHostPointer = map2;
        VkMemoryAllocateInfo ai2 = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp2, size, type };
        VkDeviceMemory mem2;
        CHECK(vkAllocateMemory(dev, &ai2, NULL, &mem2));
        CHECK(vkBindImageMemory(dev, img2, mem2, 0));
        img = img2;
    }

    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));

    // compute path: storage view in another format + shader writes, as gamescope composites
    VkImageView view = VK_NULL_HANDLE;
    VkPipeline pipe = VK_NULL_HANDLE;
    VkPipelineLayout pl = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
    if (compute) {
        FILE *f = fopen(argv[2], "rb");
        if (!f) return puts("spv"), 1;
        static uint32_t code[4096];
        size_t len = fread(code, 1, sizeof code, f);
        fclose(f);
        VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, len, code };
        VkShaderModule sm;
        CHECK(vkCreateShaderModule(dev, &smi, NULL, &sm));
        VkDescriptorSetLayoutBinding lb = { 0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT };
        VkDescriptorSetLayoutCreateInfo dli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 1, &lb };
        VkDescriptorSetLayout dsl;
        CHECK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));
        VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 4 };
        VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &dsl, 1, &pcr };
        CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
        VkComputePipelineCreateInfo cpi = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, sm, "main" },
            .layout = pl };
        CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &pipe));
        VkImageViewUsageCreateInfo vu = { VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, NULL, VK_IMAGE_USAGE_STORAGE_BIT };
        VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, &vu, 0, img, VK_IMAGE_VIEW_TYPE_2D,
                                     VK_FORMAT_R8G8B8A8_UNORM, {0}, { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        CHECK(vkCreateImageView(dev, &vi, NULL, &view));
        VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1 };
        VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &ps };
        VkDescriptorPool dp;
        CHECK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
        VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dp, 1, &dsl };
        CHECK(vkAllocateDescriptorSets(dev, &dai, &set));
        VkDescriptorImageInfo dii = { VK_NULL_HANDLE, view, VK_IMAGE_LAYOUT_GENERAL };
        VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &dii };
        vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
    }

    // source for copy/blit: an optimal device-local image (gamescope's internal composite target)
    VkImage src = VK_NULL_HANDLE;
    if (copy || blit) {
        VkImageCreateInfo si2 = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, 0, VK_IMAGE_TYPE_2D, VK_FORMAT_B8G8R8A8_UNORM,
                                  { W, H, 1 }, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL,
                                  VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_SHARING_MODE_EXCLUSIVE,
                                  0, NULL, VK_IMAGE_LAYOUT_UNDEFINED };
        CHECK(vkCreateImage(dev, &si2, NULL, &src));
        VkMemoryRequirements mr;
        vkGetImageMemoryRequirements(dev, src, &mr);
        VkPhysicalDeviceMemoryProperties mp;
        vkGetPhysicalDeviceMemoryProperties(pd, &mp);
        uint32_t t = 0;
        while (!(mr.memoryTypeBits & (1u << t))) t++;
        VkMemoryAllocateInfo sai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, t };
        VkDeviceMemory smem;
        CHECK(vkAllocateMemory(dev, &sai, NULL, &smem));
        CHECK(vkBindImageMemory(dev, src, smem, 0));
    }

    int stale = 0;
    for (int i = 0; i < 5; i++) {
        uint8_t v = (uint8_t)(40 * (i + 1));
        CHECK(vkResetCommandBuffer(cb, 0));
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CHECK(vkBeginCommandBuffer(cb, &bi));
        VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                                   VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL, 0, 0, img,
                                   { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
        VkClearColorValue c = { .float32 = { v / 255.0f, v / 255.0f, v / 255.0f, 1 } };
        VkImageSubresourceRange r = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT,
                               VK_ACCESS_HOST_READ_BIT };
        if (compute) {
            float fv = v / 255.0f;
            vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &set, 0, NULL);
            vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &fv);
            vkCmdDispatch(cb, W / 8, H / 8, 1);
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        } else if (copy || blit) {
            VkImageMemoryBarrier sb = b;
            sb.image = src;
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &sb);
            vkCmdClearColorImage(cb, src, VK_IMAGE_LAYOUT_GENERAL, &c, 1, &r);
            VkMemoryBarrier tb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT,
                                   VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT };
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &tb, 0, NULL, 0, NULL);
            VkImageSubresourceLayers sl = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
            if (copy) {
                VkImageCopy ic = { sl, { 0, 0, 0 }, sl, { 0, 0, 0 }, { W, H, 1 } };
                vkCmdCopyImage(cb, src, VK_IMAGE_LAYOUT_GENERAL, img, VK_IMAGE_LAYOUT_GENERAL, 1, &ic);
            } else {
                VkImageBlit ib = { sl, { { 0, 0, 0 }, { W, H, 1 } }, sl, { { 0, 0, 0 }, { W, H, 1 } } };
                vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_GENERAL, img, VK_IMAGE_LAYOUT_GENERAL, 1, &ib, VK_FILTER_LINEAR);
            }
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        } else {
            vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_GENERAL, &c, 1, &r);
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        }
        CHECK(vkEndCommandBuffer(cb));
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
        CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
        CHECK(vkQueueWaitIdle(q));
        printf("clear %d to %3u: driver mapping %3u, second mapping %3u\n", i, v, gpu_map[W * 4 * 100 + 400],
               reader[W * 4 * 100 + 400]);
        stale += reader[W * 4 * 100 + 400] != v;
    }
    printf("%s\n", stale ? "STALE: GPU writes do not reach the second mapping" : "coherent");
    return stale != 0;
}
