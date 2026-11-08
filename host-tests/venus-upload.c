// Guest test (Venus): gamescope's upload path — the CPU writes a host-visible, mapped buffer, the GPU copies it into a
// linear image (vkCmdCopyBufferToImage), the CPU reads the image's mapped memory. N rounds with a new value each.
// Stale reads mean guest CPU writes or GPU writes do not cross the VM boundary in time.
// Build (builder VM): gcc -O2 -o venus-upload venus-upload.c -lvulkan
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define W 256
#define H 256
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("%s -> %d\n", #x, r_); return 1; } } while (0)

static uint32_t host_visible(VkPhysicalDevice pd, uint32_t bits) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            return i;
    return UINT32_MAX;
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 8;
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);
    float prio = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
                               .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT };
    VkBuffer buf;
    CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements br;
    vkGetBufferMemoryRequirements(dev, buf, &br);
    VkMemoryAllocateInfo bai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, br.size, host_visible(pd, br.memoryTypeBits) };
    VkDeviceMemory bmem;
    CHECK(vkAllocateMemory(dev, &bai, NULL, &bmem));
    CHECK(vkBindBufferMemory(dev, buf, bmem, 0));
    uint8_t *bmap;
    CHECK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&bmap));

    VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, 0, VK_IMAGE_TYPE_2D, VK_FORMAT_B8G8R8A8_UNORM,
                             { W, H, 1 }, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_LINEAR,
                             VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL, VK_IMAGE_LAYOUT_UNDEFINED };
    VkImage img;
    CHECK(vkCreateImage(dev, &ii, NULL, &img));
    VkMemoryRequirements ir;
    vkGetImageMemoryRequirements(dev, img, &ir);
    VkMemoryAllocateInfo iai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, ir.size, host_visible(pd, ir.memoryTypeBits) };
    VkDeviceMemory imem;
    CHECK(vkAllocateMemory(dev, &iai, NULL, &imem));
    CHECK(vkBindImageMemory(dev, img, imem, 0));
    VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
    VkSubresourceLayout lay;
    vkGetImageSubresourceLayout(dev, img, &sub, &lay);
    uint8_t *imap;
    CHECK(vkMapMemory(dev, imem, 0, VK_WHOLE_SIZE, 0, (void **)&imap));

    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    CHECK(vkCreateFence(dev, &fci, NULL, &fence));

    int stale = 0;
    for (int i = 0; i < rounds; i++) {
        uint8_t v = (uint8_t)(17 * (i + 1));
        memset(bmap, v, W * H * 4); // the CPU side of gamescope's upload buffer
        CHECK(vkResetCommandBuffer(cb, 0));
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CHECK(vkBeginCommandBuffer(cb, &bi));
        VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                                   VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL, 0, 0, img,
                                   { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
        VkBufferImageCopy c = { 0, 0, 0, { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, { 0, 0, 0 }, { W, H, 1 } };
        vkCmdCopyBufferToImage(cb, buf, img, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
        VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        CHECK(vkEndCommandBuffer(cb));
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
        CHECK(vkResetFences(dev, 1, &fence));
        CHECK(vkQueueSubmit(q, 1, &si, fence));
        CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
        uint8_t got = imap[lay.offset + lay.rowPitch * 100 + 400];
        printf("round %d: wrote %3u, image reads %3u\n", i, v, got);
        stale += got != v;
    }
    printf("%s\n", stale ? "STALE: upload path loses data across the VM boundary" : "coherent");
    return stale != 0;
}
