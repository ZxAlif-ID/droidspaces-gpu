/* gpu_demo.c — minimal Vulkan compute demo proving the Adreno GPU really
 * executes work under turnip + kgsl on a droidspaces Ubuntu rootfs.
 *
 * What it does:
 *   1. Creates a Vulkan instance and enumerates physical devices.
 *   2. Requires an Adreno device (fails loudly if only llvmpipe is found —
 *      running on the CPU renderer would silently fake "success").
 *   3. Allocates a 256-float storage buffer in device memory, uploads a
 *      known input pattern, dispatches shader.comp (v[i] = v[i]*v[i] + i),
 *      waits for the queue, maps the buffer back and verifies every value
 *      against a CPU-computed reference.
 *   4. Prints device info, dispatch size and "ALL CHECKS PASSED" on success.
 *
 * Build:  cmake -S demo -B demo/build && cmake --build demo/build
 * Run:    source scripts/gpu-env.sh && demo/build/gpu-demo
 * (the three env vars from gpu-env.sh decide which driver it talks to)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <vulkan/vulkan.h>
#include "shader_spv.h"   /* generated from shader.comp + shader_const.comp */

#define N_ELEMS   256
#define WG_SIZE   64
#define CHECK(x)  do { VkResult _r = (x); if (_r != VK_SUCCESS) { \
    fprintf(stderr, "FATAL: %s failed with VkResult %d at line %d\n", \
            #x, _r, __LINE__); exit(1); } } while (0)

/* Select the kernel: DEMO_SHADER=math (default) or DEMO_SHADER=const.
 * const writes 42.0 everywhere — a pure write-path probe with no math. */
static int use_const = 0;

/* Verify device output against a CPU copy of the input. */
static int verify(const float *host, const float *in, int n) {
    int errors = 0;
    for (int i = 0; i < n; i++) {
        float want = use_const ? 42.0f : in[i] * in[i] + (float)i;
        if (host[i] != want) {
            if (errors < 5)
                fprintf(stderr, "  mismatch [%d]: got %.1f want %.1f\n", i, host[i], want);
            errors++;
        }
    }
    return errors;
}

int main(void) {
    double t0 = (double)clock() / CLOCKS_PER_SEC;

    /* kernel selection: DEMO_SHADER=const probes the raw write path */
    {
        const char *mode = getenv("DEMO_SHADER");
        if (mode && strcmp(mode, "const") == 0) {
            use_const = 1;
        }
        printf("kernel: %s\n", use_const ? "const (v[i] = 42.0)" : "math (v[i] = v[i]^2 + i)");
    }

    /* 1. instance ------------------------------------------------------- */
    VkApplicationInfo app = {0};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "droidspaces-gpu-demo";
    app.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo ici = {0};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;

    VkInstance instance;
    /* A broken/no Vulkan install (missing ICDs, dangling layers) is the
     * documented "no GPU here" outcome — exit 2, not a crash. */
    VkResult ir = vkCreateInstance(&ici, NULL, &instance);
    if (ir != VK_SUCCESS) {
        fprintf(stderr, "no usable Vulkan on this system: vkCreateInstance = %d\n"
                "  (-9 = VK_ERROR_LAYER_NOT_PRESENT: dangling layer config)\n", (int)ir);
        return 2;
    }

    /* 2. pick the Adreno physical device (never llvmpipe) --------------- */
    uint32_t n = 0;
    CHECK(vkEnumeratePhysicalDevices(instance, &n, NULL));
    if (n == 0) {
        fprintf(stderr, "FATAL: no Vulkan physical devices found. Is\n"
                "  LD_PRELOAD/VK_ICD_FILENAMES/TU_DEBUG set? See scripts/gpu-env.sh\n");
        return 2;
    }
    VkPhysicalDevice *pdevs = malloc(n * sizeof(VkPhysicalDevice));
    CHECK(vkEnumeratePhysicalDevices(instance, &n, pdevs));

    VkPhysicalDevice pdev = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties props = {0};
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p = {0};
        vkGetPhysicalDeviceProperties(pdevs[i], &p);
        printf("device %u: %s (type %d, api %u.%u.%u)\n", i, p.deviceName,
               p.deviceType, VK_API_VERSION_MAJOR(p.apiVersion),
               VK_API_VERSION_MINOR(p.apiVersion), VK_API_VERSION_PATCH(p.apiVersion));
        if (strstr(p.deviceName, "Adreno") && pdev == VK_NULL_HANDLE) {
            pdev = pdevs[i];
            props = p;
        }
    }
    if (pdev == VK_NULL_HANDLE) {
        fprintf(stderr, "FATAL: no Adreno device — the loader only offered the\n"
                "  CPU renderer (llvmpipe). The GPU env vars are wrong or the\n"
                "  driver failed to load. See docs/troubleshooting.md\n");
        return 2;
    }
    printf("selected: %s | driver-consistent, computing on GPU\n", props.deviceName);

    /* 3. compute queue family ------------------------------------------- */
    uint32_t nfam = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nfam, NULL);
    VkQueueFamilyProperties *fams = malloc(nfam * sizeof(*fams));
    vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nfam, fams);
    int qfam = -1;
    for (uint32_t i = 0; i < nfam; i++)
        if (fams[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qfam = (int)i; break; }
    if (qfam < 0) { fprintf(stderr, "FATAL: no compute queue\n"); return 2; }

    float qprio = 1.0f;
    VkDeviceQueueCreateInfo qci = {0};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = (uint32_t)qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &qprio;

    VkDeviceCreateInfo dci = {0};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;

    VkDevice dev;
    CHECK(vkCreateDevice(pdev, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, (uint32_t)qfam, 0, &queue);

    /* 4. buffer + host-visible memory ----------------------------------- */
    VkBufferCreateInfo bci = {0};
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size = N_ELEMS * sizeof(float);
    bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    VkBuffer buf;
    CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));

    VkMemoryRequirements mreq;
    vkGetBufferMemoryRequirements(dev, buf, &mreq);
    VkPhysicalDeviceMemoryProperties memprops;
    vkGetPhysicalDeviceMemoryProperties(pdev, &memprops);
    int memidx = -1;
    for (uint32_t i = 0; i < memprops.memoryTypeCount; i++) {
        VkMemoryType mt = memprops.memoryTypes[i];
        if ((mreq.memoryTypeBits & (1u << i)) &&
            (mt.propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (mt.propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            memidx = (int)i; break;
        }
    }
    if (memidx < 0) { fprintf(stderr, "FATAL: no host-visible memtype\n"); return 2; }

    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = mreq.size;
    mai.memoryTypeIndex = (uint32_t)memidx;
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
    CHECK(vkBindBufferMemory(dev, buf, mem, 0));

    float *host;
    CHECK(vkMapMemory(dev, mem, 0, N_ELEMS * sizeof(float), 0, (void **)&host));
    for (int i = 0; i < N_ELEMS; i++)
        host[i] = (float)(i % 17) + 1.0f;   /* known input pattern */

    /* keep a CPU copy of the input for verification */
    static float inref[N_ELEMS];
    memcpy(inref, host, sizeof inref);

    /* 5. descriptor set -------------------------------------------------- */
    VkDescriptorSetLayoutBinding bind = {0};
    bind.binding = 0;
    bind.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    bind.descriptorCount = 1;
    bind.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;

    VkDescriptorSetLayoutCreateInfo dlci = {0};
    dlci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    dlci.bindingCount = 1;
    dlci.pBindings = &bind;
    VkDescriptorSetLayout dlayout;
    CHECK(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dlayout));

    VkDescriptorPoolSize psize = {0};
    psize.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    psize.descriptorCount = 1;
    VkDescriptorPoolCreateInfo pci = {0};
    pci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pci.maxSets = 1;
    pci.poolSizeCount = 1;
    pci.pPoolSizes = &psize;
    VkDescriptorPool pool;
    CHECK(vkCreateDescriptorPool(dev, &pci, NULL, &pool));

    VkDescriptorSetAllocateInfo dai = {0};
    dai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    dai.descriptorPool = pool;
    dai.descriptorSetCount = 1;
    dai.pSetLayouts = &dlayout;
    VkDescriptorSet dset;
    CHECK(vkAllocateDescriptorSets(dev, &dai, &dset));

    VkDescriptorBufferInfo dbi = {0};
    dbi.buffer = buf;
    dbi.offset = 0;
    dbi.range = VK_WHOLE_SIZE;
    VkWriteDescriptorSet wds = {0};
    wds.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    wds.dstSet = dset;
    wds.dstBinding = 0;
    wds.descriptorCount = 1;
    wds.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    wds.pBufferInfo = &dbi;
    vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);

    /* 6. shader module + pipeline ---------------------------------------- */
    VkShaderModuleCreateInfo smci = {0};
    smci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    smci.codeSize = use_const ? shader_const_spv_len : shader_spv_len;
    smci.pCode = use_const ? shader_const_spv : shader_spv;
    VkShaderModule smod;
    CHECK(vkCreateShaderModule(dev, &smci, NULL, &smod));

    VkPipelineShaderStageCreateInfo stage = {0};
    stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    stage.module = smod;
    stage.pName = "main";

    VkPipelineLayoutCreateInfo plci = {0};
    plci.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    plci.setLayoutCount = 1;
    plci.pSetLayouts = &dlayout;
    VkPipelineLayout playout;
    CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &playout));

    VkComputePipelineCreateInfo cpci = {0};
    cpci.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    cpci.stage = stage;
    cpci.layout = playout;
    VkPipeline pipe;
    CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

    /* 7. command buffer + dispatch --------------------------------------- */
    VkCommandPoolCreateInfo cpolci = {0};
    cpolci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpolci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpolci.queueFamilyIndex = (uint32_t)qfam;
    VkCommandPool cpool;
    CHECK(vkCreateCommandPool(dev, &cpolci, NULL, &cpool));

    VkCommandBufferAllocateInfo cai = {0};
    cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = cpool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(dev, &cai, &cmd));

    VkCommandBufferBeginInfo bbi = {0};
    bbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CHECK(vkBeginCommandBuffer(cmd, &bbi));
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, playout,
                            0, 1, &dset, 0, NULL);
    vkCmdDispatch(cmd, N_ELEMS / WG_SIZE, 1, 1);
    CHECK(vkEndCommandBuffer(cmd));

    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));

    /* 8. verify against CPU reference ------------------------------------- */
    int errors = verify(host, inref, N_ELEMS);
    double t1 = (double)clock() / CLOCKS_PER_SEC;

    printf("dispatch: %u workgroups x %u invocations = %d elements\n",
           N_ELEMS / WG_SIZE, WG_SIZE, N_ELEMS);
    printf("verification: %d/%d values correct (%.3f s wall, incl. device init)\n",
           N_ELEMS - errors, N_ELEMS, t1 - t0);

    /* cleanup ------------------------------------------------------------- */
    vkDestroyPipeline(dev, pipe, NULL);
    vkDestroyPipelineLayout(dev, playout, NULL);
    vkDestroyShaderModule(dev, smod, NULL);
    vkDestroyDescriptorPool(dev, pool, NULL);
    vkDestroyDescriptorSetLayout(dev, dlayout, NULL);
    vkDestroyCommandPool(dev, cpool, NULL);
    vkUnmapMemory(dev, mem);
    vkFreeMemory(dev, mem, NULL);
    vkDestroyBuffer(dev, buf, NULL);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(instance, NULL);
    free(pdevs); free(fams);

    if (errors) {
        fprintf(stderr, "FAIL: %d of %d values wrong — dispatch did not compute correctly\n",
                errors, N_ELEMS);
        return 1;
    }
    printf("ALL CHECKS PASSED — the GPU executed the compute dispatch correctly\n");
    return 0;
}
