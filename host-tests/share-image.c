/* Shares an optimal-tiled image between two Vulkan devices through an opaque fd, as Wine/DXVK do for D3D11 shared
 * resources (Media Foundation video frames): device A clears it to a known colour, device B imports the memory into
 * an identical image and reads a pixel back. "fork" puts B in a second process (fd over a unix socket), otherwise
 * both devices live in one process. Prints PASS/FAIL. Build: gcc -O2 -o share-image share-image.c -lvulkan */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define W 64
#define H 64
#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

struct dev { VkPhysicalDevice pd; VkDevice d; VkQueue q; VkCommandPool pool; };

static VkInstance instance(void)
{
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    return inst;
}

static struct dev device(VkInstance inst)
{
    struct dev v;
    uint32_t n = 1;
    vkEnumeratePhysicalDevices(inst, &n, &v.pd);
    const char *exts[] = {"VK_KHR_external_memory_fd"};
    float prio = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
                                   .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                              .pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = exts};
    CHECK(vkCreateDevice(v.pd, &dci, NULL, &v.d));
    vkGetDeviceQueue(v.d, 0, 0, &v.q);
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    CHECK(vkCreateCommandPool(v.d, &pci, NULL, &v.pool));
    return v;
}

static uint32_t mem_type(struct dev *v, uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags avoid)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(v->pd, &mp);
    for (int pass = 0; pass < 2; pass++)
        for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
            if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want &&
                (pass || !(mp.memoryTypes[i].propertyFlags & avoid)))
                return i;
    printf("FAIL no memory type\n");
    exit(1);
}

/* the shared image with its memory, exported (fd < 0) or imported (fd >= 0) */
static VkImage shared_image(struct dev *v, int *fd)
{
    VkExternalMemoryImageCreateInfo ext = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
                                           .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT};
    VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &ext, .imageType = VK_IMAGE_TYPE_2D,
                             .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1}, .mipLevels = 1, .arrayLayers = 1,
                             .samples = 1, .tiling = VK_IMAGE_TILING_OPTIMAL,
                             .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                      VK_IMAGE_USAGE_SAMPLED_BIT};
    VkImage img;
    CHECK(vkCreateImage(v->d, &ici, NULL, &img));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(v->d, img, &req);
    VkMemoryDedicatedAllocateInfo ded = {.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = img};
    VkExportMemoryAllocateInfo exp = {.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO, .pNext = &ded,
                                      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT};
    VkImportMemoryFdInfoKHR imp = {.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .pNext = &ded,
                                   .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT, .fd = *fd};
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .pNext = *fd >= 0 ? (void *)&imp : (void *)&exp, .allocationSize = req.size,
                                .memoryTypeIndex = mem_type(v, req.memoryTypeBits,
                                                            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                                                            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)};
    printf("%s: size %llu type %u\n", *fd >= 0 ? "import" : "export", (unsigned long long)req.size,
           mai.memoryTypeIndex);
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(v->d, &mai, NULL, &mem));
    CHECK(vkBindImageMemory(v->d, img, mem, 0));
    if (*fd < 0) {
        PFN_vkGetMemoryFdKHR get_fd = (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(v->d, "vkGetMemoryFdKHR");
        VkMemoryGetFdInfoKHR gfi = {.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR, .memory = mem,
                                    .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT};
        CHECK(get_fd(v->d, &gfi, fd));
    }
    return img;
}

static VkCommandBuffer begin(struct dev *v)
{
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = v->pool,
                                      .commandBufferCount = 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(v->d, &ai, &cb));
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(cb, &bi));
    return cb;
}

static void submit(struct dev *v, VkCommandBuffer cb)
{
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    CHECK(vkQueueSubmit(v->q, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(v->q));
}

static void barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to)
{
    VkImageMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
                              .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                              .oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                              .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
                              .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
                         NULL, 1, &b);
}

static void exporter(struct dev *a, int *fd)
{
    VkImage img = shared_image(a, fd);
    VkCommandBuffer cb = begin(a);
    barrier(cb, img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    VkClearColorValue c = {.float32 = {0.25f, 0.5f, 0.75f, 1.0f}};
    VkImageSubresourceRange r = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &c, 1, &r);
    barrier(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL);
    submit(a, cb);
    printf("export: cleared, fd %d\n", *fd);
}

static int importer(struct dev *b, int fd)
{
    VkImage img = shared_image(b, &fd);
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
                              .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VkBuffer buf;
    CHECK(vkCreateBuffer(b->d, &bci, NULL, &buf));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(b->d, buf, &req);
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
                                .memoryTypeIndex = mem_type(b, req.memoryTypeBits,
                                                            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, 0)};
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(b->d, &mai, NULL, &mem));
    CHECK(vkBindBufferMemory(b->d, buf, mem, 0));
    VkCommandBuffer cb = begin(b);
    /* the content survives only if the layout is kept: GENERAL on both sides */
    barrier(cb, img, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &copy);
    submit(b, cb);
    unsigned char *p;
    CHECK(vkMapMemory(b->d, mem, 0, VK_WHOLE_SIZE, 0, (void **)&p));
    unsigned char *q = p + ((H / 2) * W + W / 2) * 4;
    printf("import: pixel %u %u %u %u (want ~64 128 191 255)\n", q[0], q[1], q[2], q[3]);
    int ok = abs(q[0] - 64) <= 1 && abs(q[1] - 128) <= 1 && abs(q[2] - 191) <= 1 && q[3] == 255;
    printf("%s\n", ok ? "PASS" : "FAIL wrong pixel");
    return !ok;
}

static void send_fd(int sock, int fd)
{
    char c = 0, ctrl[CMSG_SPACE(sizeof(int))] = {0};
    struct iovec iov = {&c, 1};
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof(ctrl)};
    struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
    cm->cmsg_level = SOL_SOCKET, cm->cmsg_type = SCM_RIGHTS, cm->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &fd, sizeof(int));
    sendmsg(sock, &m, 0);
}

static int recv_fd(int sock)
{
    char c, ctrl[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {&c, 1};
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof(ctrl)};
    if (recvmsg(sock, &m, 0) <= 0) return -1;
    int fd;
    memcpy(&fd, CMSG_DATA(CMSG_FIRSTHDR(&m)), sizeof(int));
    return fd;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && !strcmp(argv[1], "fork")) {
        int sv[2];
        socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
        pid_t pid = fork();
        if (pid == 0) { /* importer process */
            VkInstance inst = instance();
            struct dev b = device(inst);
            int fd = recv_fd(sv[1]);
            int rc = importer(&b, fd);
            write(sv[1], "x", 1); /* exporter may free now */
            return rc;
        }
        VkInstance inst = instance();
        struct dev a = device(inst);
        int fd = -1;
        exporter(&a, &fd);
        send_fd(sv[0], fd);
        char c;
        read(sv[0], &c, 1);
        int status;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    VkInstance inst = instance();
    struct dev a = device(inst), b = device(inst);
    int fd = -1;
    exporter(&a, &fd);
    return importer(&b, fd);
}
