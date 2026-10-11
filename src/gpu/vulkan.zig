const std = @import("std");
const builtin = @import("builtin");
const spirv = @import("spirv");
const mod = @import("mod.zig");
const cpu = @import("cpu");

const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const VulkanLoader = struct {
    lib: std.DynLib,
    getProcAddr: c.PFN_vkGetInstanceProcAddr,

    fn load() !VulkanLoader {
        const lib_names = switch (builtin.os.tag) {
            .macos => &[_][]const u8{
                "libMoltenVK.dylib",
                "libvulkan.1.dylib",
                "libvulkan.dylib",
                "/opt/homebrew/lib/libMoltenVK.dylib",
                "/opt/homebrew/lib/libvulkan.1.dylib",
                "/usr/local/lib/libMoltenVK.dylib",
                "/usr/local/lib/libvulkan.1.dylib",
            },
            .linux => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
            .windows => &[_][]const u8{"vulkan-1.dll"},
            else => return error.UnsupportedPlatform,
        };

        for (lib_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(c.PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{ .lib = lib, .getProcAddr = proc };
            }
            lib.close();
        }
        return error.VulkanNotFound;
    }
};

var vulkan_loader: ?VulkanLoader = null;

fn getVkGetInstanceProcAddr() !c.PFN_vkGetInstanceProcAddr {
    if (vulkan_loader) |loader| return loader.getProcAddr;
    vulkan_loader = try VulkanLoader.load();
    return vulkan_loader.?.getProcAddr;
}

fn loadFn(comptime T: type, gpa: c.PFN_vkGetInstanceProcAddr, instance: c.VkInstance, name: [*:0]const u8) std.meta.Child(T) {
    const gpa_nonnull = gpa orelse {
        std.debug.print("vkGetInstanceProcAddr is null\n", .{});
        @panic("vkGetInstanceProcAddr is null");
    };
    const proc = gpa_nonnull(instance, name) orelse {
        std.debug.print("Failed to load Vulkan function: {s}\n", .{name});
        @panic("Vulkan function not found");
    };
    return @ptrCast(proc);
}

const VulkanFns = struct {
    createInstance: std.meta.Child(c.PFN_vkCreateInstance),
    destroyInstance: std.meta.Child(c.PFN_vkDestroyInstance),
    enumeratePhysicalDevices: std.meta.Child(c.PFN_vkEnumeratePhysicalDevices),
    getPhysicalDeviceProperties: std.meta.Child(c.PFN_vkGetPhysicalDeviceProperties),
    getPhysicalDeviceQueueFamilyProperties: std.meta.Child(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties),
    getPhysicalDeviceMemoryProperties: std.meta.Child(c.PFN_vkGetPhysicalDeviceMemoryProperties),
    createDevice: std.meta.Child(c.PFN_vkCreateDevice),
    getDeviceProcAddr: std.meta.Child(c.PFN_vkGetDeviceProcAddr),
    destroyDevice: std.meta.Child(c.PFN_vkDestroyDevice),
    getDeviceQueue: std.meta.Child(c.PFN_vkGetDeviceQueue),
    createBuffer: std.meta.Child(c.PFN_vkCreateBuffer),
    getBufferMemoryRequirements: std.meta.Child(c.PFN_vkGetBufferMemoryRequirements),
    allocateMemory: std.meta.Child(c.PFN_vkAllocateMemory),
    bindBufferMemory: std.meta.Child(c.PFN_vkBindBufferMemory),
    mapMemory: std.meta.Child(c.PFN_vkMapMemory),
    unmapMemory: std.meta.Child(c.PFN_vkUnmapMemory),
    freeMemory: std.meta.Child(c.PFN_vkFreeMemory),
    destroyBuffer: std.meta.Child(c.PFN_vkDestroyBuffer),
    createShaderModule: std.meta.Child(c.PFN_vkCreateShaderModule),
    destroyShaderModule: std.meta.Child(c.PFN_vkDestroyShaderModule),
    createDescriptorSetLayout: std.meta.Child(c.PFN_vkCreateDescriptorSetLayout),
    destroyDescriptorSetLayout: std.meta.Child(c.PFN_vkDestroyDescriptorSetLayout),
    createPipelineLayout: std.meta.Child(c.PFN_vkCreatePipelineLayout),
    destroyPipelineLayout: std.meta.Child(c.PFN_vkDestroyPipelineLayout),
    createComputePipelines: std.meta.Child(c.PFN_vkCreateComputePipelines),
    destroyPipeline: std.meta.Child(c.PFN_vkDestroyPipeline),
    createDescriptorPool: std.meta.Child(c.PFN_vkCreateDescriptorPool),
    destroyDescriptorPool: std.meta.Child(c.PFN_vkDestroyDescriptorPool),
    allocateDescriptorSets: std.meta.Child(c.PFN_vkAllocateDescriptorSets),
    updateDescriptorSets: std.meta.Child(c.PFN_vkUpdateDescriptorSets),
    createCommandPool: std.meta.Child(c.PFN_vkCreateCommandPool),
    destroyCommandPool: std.meta.Child(c.PFN_vkDestroyCommandPool),
    allocateCommandBuffers: std.meta.Child(c.PFN_vkAllocateCommandBuffers),
    freeCommandBuffers: std.meta.Child(c.PFN_vkFreeCommandBuffers),
    beginCommandBuffer: std.meta.Child(c.PFN_vkBeginCommandBuffer),
    endCommandBuffer: std.meta.Child(c.PFN_vkEndCommandBuffer),
    cmdBindPipeline: std.meta.Child(c.PFN_vkCmdBindPipeline),
    cmdBindDescriptorSets: std.meta.Child(c.PFN_vkCmdBindDescriptorSets),
    cmdDispatch: std.meta.Child(c.PFN_vkCmdDispatch),
    createFence: std.meta.Child(c.PFN_vkCreateFence),
    destroyFence: std.meta.Child(c.PFN_vkDestroyFence),
    queueSubmit: std.meta.Child(c.PFN_vkQueueSubmit),
    waitForFences: std.meta.Child(c.PFN_vkWaitForFences),
    resetFences: std.meta.Child(c.PFN_vkResetFences),
};

fn loadInstanceFns(gpa: c.PFN_vkGetInstanceProcAddr, instance: c.VkInstance) VulkanFns {
    return .{
        .createInstance = loadFn(c.PFN_vkCreateInstance, gpa, instance, "vkCreateInstance"),
        .destroyInstance = loadFn(c.PFN_vkDestroyInstance, gpa, instance, "vkDestroyInstance"),
        .enumeratePhysicalDevices = loadFn(c.PFN_vkEnumeratePhysicalDevices, gpa, instance, "vkEnumeratePhysicalDevices"),
        .getPhysicalDeviceProperties = loadFn(c.PFN_vkGetPhysicalDeviceProperties, gpa, instance, "vkGetPhysicalDeviceProperties"),
        .getPhysicalDeviceQueueFamilyProperties = loadFn(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties, gpa, instance, "vkGetPhysicalDeviceQueueFamilyProperties"),
        .getPhysicalDeviceMemoryProperties = loadFn(c.PFN_vkGetPhysicalDeviceMemoryProperties, gpa, instance, "vkGetPhysicalDeviceMemoryProperties"),
        .createDevice = loadFn(c.PFN_vkCreateDevice, gpa, instance, "vkCreateDevice"),
        .getDeviceProcAddr = loadFn(c.PFN_vkGetDeviceProcAddr, gpa, instance, "vkGetDeviceProcAddr"),
        .destroyDevice = loadFn(c.PFN_vkDestroyDevice, gpa, instance, "vkDestroyDevice"),
        .getDeviceQueue = loadFn(c.PFN_vkGetDeviceQueue, gpa, instance, "vkGetDeviceQueue"),
        .createBuffer = loadFn(c.PFN_vkCreateBuffer, gpa, instance, "vkCreateBuffer"),
        .getBufferMemoryRequirements = loadFn(c.PFN_vkGetBufferMemoryRequirements, gpa, instance, "vkGetBufferMemoryRequirements"),
        .allocateMemory = loadFn(c.PFN_vkAllocateMemory, gpa, instance, "vkAllocateMemory"),
        .bindBufferMemory = loadFn(c.PFN_vkBindBufferMemory, gpa, instance, "vkBindBufferMemory"),
        .mapMemory = loadFn(c.PFN_vkMapMemory, gpa, instance, "vkMapMemory"),
        .unmapMemory = loadFn(c.PFN_vkUnmapMemory, gpa, instance, "vkUnmapMemory"),
        .freeMemory = loadFn(c.PFN_vkFreeMemory, gpa, instance, "vkFreeMemory"),
        .destroyBuffer = loadFn(c.PFN_vkDestroyBuffer, gpa, instance, "vkDestroyBuffer"),
        .createShaderModule = loadFn(c.PFN_vkCreateShaderModule, gpa, instance, "vkCreateShaderModule"),
        .destroyShaderModule = loadFn(c.PFN_vkDestroyShaderModule, gpa, instance, "vkDestroyShaderModule"),
        .createDescriptorSetLayout = loadFn(c.PFN_vkCreateDescriptorSetLayout, gpa, instance, "vkCreateDescriptorSetLayout"),
        .destroyDescriptorSetLayout = loadFn(c.PFN_vkDestroyDescriptorSetLayout, gpa, instance, "vkDestroyDescriptorSetLayout"),
        .createPipelineLayout = loadFn(c.PFN_vkCreatePipelineLayout, gpa, instance, "vkCreatePipelineLayout"),
        .destroyPipelineLayout = loadFn(c.PFN_vkDestroyPipelineLayout, gpa, instance, "vkDestroyPipelineLayout"),
        .createComputePipelines = loadFn(c.PFN_vkCreateComputePipelines, gpa, instance, "vkCreateComputePipelines"),
        .destroyPipeline = loadFn(c.PFN_vkDestroyPipeline, gpa, instance, "vkDestroyPipeline"),
        .createDescriptorPool = loadFn(c.PFN_vkCreateDescriptorPool, gpa, instance, "vkCreateDescriptorPool"),
        .destroyDescriptorPool = loadFn(c.PFN_vkDestroyDescriptorPool, gpa, instance, "vkDestroyDescriptorPool"),
        .allocateDescriptorSets = loadFn(c.PFN_vkAllocateDescriptorSets, gpa, instance, "vkAllocateDescriptorSets"),
        .updateDescriptorSets = loadFn(c.PFN_vkUpdateDescriptorSets, gpa, instance, "vkUpdateDescriptorSets"),
        .createCommandPool = loadFn(c.PFN_vkCreateCommandPool, gpa, instance, "vkCreateCommandPool"),
        .destroyCommandPool = loadFn(c.PFN_vkDestroyCommandPool, gpa, instance, "vkDestroyCommandPool"),
        .allocateCommandBuffers = loadFn(c.PFN_vkAllocateCommandBuffers, gpa, instance, "vkAllocateCommandBuffers"),
        .freeCommandBuffers = loadFn(c.PFN_vkFreeCommandBuffers, gpa, instance, "vkFreeCommandBuffers"),
        .beginCommandBuffer = loadFn(c.PFN_vkBeginCommandBuffer, gpa, instance, "vkBeginCommandBuffer"),
        .endCommandBuffer = loadFn(c.PFN_vkEndCommandBuffer, gpa, instance, "vkEndCommandBuffer"),
        .cmdBindPipeline = loadFn(c.PFN_vkCmdBindPipeline, gpa, instance, "vkCmdBindPipeline"),
        .cmdBindDescriptorSets = loadFn(c.PFN_vkCmdBindDescriptorSets, gpa, instance, "vkCmdBindDescriptorSets"),
        .cmdDispatch = loadFn(c.PFN_vkCmdDispatch, gpa, instance, "vkCmdDispatch"),
        .createFence = loadFn(c.PFN_vkCreateFence, gpa, instance, "vkCreateFence"),
        .destroyFence = loadFn(c.PFN_vkDestroyFence, gpa, instance, "vkDestroyFence"),
        .queueSubmit = loadFn(c.PFN_vkQueueSubmit, gpa, instance, "vkQueueSubmit"),
        .waitForFences = loadFn(c.PFN_vkWaitForFences, gpa, instance, "vkWaitForFences"),
        .resetFences = loadFn(c.PFN_vkResetFences, gpa, instance, "vkResetFences"),
    };
}

pub const VulkanProver = struct {
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    compute_queue: c.VkQueue,
    compute_queue_family: u32,

    // G1 v5 pipelines
    msm_g1_v5_br_pipeline: c.VkPipeline,
    msm_g1_v5_br_pipeline_layout: c.VkPipelineLayout,
    msm_g1_v5_br_descriptor_set_layout: c.VkDescriptorSetLayout,
    msm_g1_v5_br_shader_module: c.VkShaderModule,

    msm_g1_v5_wr_pipeline: c.VkPipeline,
    msm_g1_v5_wr_pipeline_layout: c.VkPipelineLayout,
    msm_g1_v5_wr_descriptor_set_layout: c.VkDescriptorSetLayout,
    msm_g1_v5_wr_shader_module: c.VkShaderModule,

    // G2 v6 pipelines
    msm_g2_v6_br_pipeline: c.VkPipeline,
    msm_g2_v6_br_pipeline_layout: c.VkPipelineLayout,
    msm_g2_v6_br_descriptor_set_layout: c.VkDescriptorSetLayout,
    msm_g2_v6_br_shader_module: c.VkShaderModule,

    msm_g2_v6_wr_pipeline: c.VkPipeline,
    msm_g2_v6_wr_pipeline_layout: c.VkPipelineLayout,
    msm_g2_v6_wr_descriptor_set_layout: c.VkDescriptorSetLayout,
    msm_g2_v6_wr_shader_module: c.VkShaderModule,

    descriptor_pool: c.VkDescriptorPool,
    command_pool: c.VkCommandPool,
    fence: c.VkFence,
    mem_props: c.VkPhysicalDeviceMemoryProperties,

    allocator: std.mem.Allocator,
    fns: VulkanFns,
    capabilities: mod.GpuCapabilities,

    const Self = @This();
    const BufferAllocation = struct { buffer: c.VkBuffer, memory: c.VkDeviceMemory, size: c.VkDeviceSize, mapped: ?*anyopaque };

    fn createShaderModule(device: c.VkDevice, fns: VulkanFns, code: []const u8) !c.VkShaderModule {
        // SPIR-V code must be 4-byte aligned. Copy to an aligned buffer if needed.
        const aligned_code = if (@intFromPtr(code.ptr) % 4 == 0)
            code
        else blk: {
            const aligned = try std.heap.page_allocator.alloc(u8, code.len);
            @memcpy(aligned, code);
            break :blk aligned;
        };
        defer if (@intFromPtr(code.ptr) % 4 != 0) std.heap.page_allocator.free(aligned_code);

        const create_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = aligned_code.len,
            .pCode = @ptrCast(@alignCast(aligned_code.ptr)),
        };
        var shader_module: c.VkShaderModule = undefined;
        const res = fns.createShaderModule(device, &create_info, null, &shader_module);
        if (res != c.VK_SUCCESS) return error.ShaderModuleCreationFailed;
        return shader_module;
    }

    fn createComputePipeline(device: c.VkDevice, fns: VulkanFns, shader_module: c.VkShaderModule, pipeline_layout: c.VkPipelineLayout) !c.VkPipeline {
        const stage = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };
        const create_info = c.VkComputePipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = stage,
            .layout = pipeline_layout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: c.VkPipeline = undefined;
        const res = fns.createComputePipelines(device, null, 1, &create_info, null, &pipeline);
        if (res != c.VK_SUCCESS) return error.PipelineCreationFailed;
        return pipeline;
    }

    fn createDescriptorSetLayout(device: c.VkDevice, fns: VulkanFns, bindings: []const c.VkDescriptorSetLayoutBinding) !c.VkDescriptorSetLayout {
        const create_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = @intCast(bindings.len),
            .pBindings = bindings.ptr,
        };
        var layout: c.VkDescriptorSetLayout = undefined;
        const res = fns.createDescriptorSetLayout(device, &create_info, null, &layout);
        if (res != c.VK_SUCCESS) return error.DescriptorSetLayoutCreationFailed;
        return layout;
    }

    fn createPipelineLayout(device: c.VkDevice, fns: VulkanFns, set_layout: c.VkDescriptorSetLayout) !c.VkPipelineLayout {
        const create_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        var layout: c.VkPipelineLayout = undefined;
        const res = fns.createPipelineLayout(device, &create_info, null, &layout);
        if (res != c.VK_SUCCESS) return error.PipelineLayoutCreationFailed;
        return layout;
    }

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const gpa = try getVkGetInstanceProcAddr();

        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "prover",
            .applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
            .pEngineName = "prover",
            .engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_2,
        };

        const instance_create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };

        var instance: c.VkInstance = undefined;
        const gpa2 = loadFn(c.PFN_vkCreateInstance, gpa, null, "vkCreateInstance");
        var res = gpa2(&instance_create_info, null, &instance);
        if (res != c.VK_SUCCESS) {
            std.debug.print("vkCreateInstance failed with result: {d}\n", .{res});
            return error.InstanceCreationFailed;
        }
        errdefer {
            const destroy = loadFn(c.PFN_vkDestroyInstance, gpa, instance, "vkDestroyInstance");
            destroy(instance, null);
        }

        const fns = loadInstanceFns(gpa, instance);

        var device_count: u32 = 0;
        _ = fns.enumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;

        var physical_devices: [16]c.VkPhysicalDevice = undefined;
        device_count = @min(device_count, 16);
        _ = fns.enumeratePhysicalDevices(instance, &device_count, &physical_devices);

        var selected_device: ?c.VkPhysicalDevice = null;
        var selected_queue_family: u32 = 0;
        var selected_props: c.VkPhysicalDeviceProperties = undefined;

        for (physical_devices[0..device_count]) |pdev| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            fns.getPhysicalDeviceProperties(pdev, &props);

            var queue_count: u32 = 0;
            fns.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);
            var queue_props: [32]c.VkQueueFamilyProperties = undefined;
            queue_count = @min(queue_count, 32);
            fns.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, &queue_props);

            for (queue_props[0..queue_count], 0..) |qp, i| {
                if ((qp.queueFlags & c.VK_QUEUE_COMPUTE_BIT) != 0) {
                    if (selected_device == null or
                        (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and selected_props.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU))
                    {
                        selected_device = pdev;
                        selected_queue_family = @intCast(i);
                        selected_props = props;
                    }
                    break;
                }
            }
        }

        const physical_device = selected_device orelse return error.NoComputeQueue;

        const queue_priority: f32 = 1.0;
        const queue_create_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = selected_queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .pEnabledFeatures = null,
        };

        var device: c.VkDevice = undefined;
        res = fns.createDevice(physical_device, &device_create_info, null, &device);
        if (res != c.VK_SUCCESS) return error.DeviceCreationFailed;
        errdefer fns.destroyDevice(device, null);

        var compute_queue: c.VkQueue = undefined;
        fns.getDeviceQueue(device, selected_queue_family, 0, &compute_queue);

        // Create shader modules
        const msm_g1_v5_br_shader = try createShaderModule(device, fns, spirv.MSM_G1_V5_BUCKET_REDUCE);
        errdefer fns.destroyShaderModule(device, msm_g1_v5_br_shader, null);
        const msm_g1_v5_wr_shader = try createShaderModule(device, fns, spirv.MSM_G1_V5_WINDOW_REDUCE);
        errdefer fns.destroyShaderModule(device, msm_g1_v5_wr_shader, null);
        const msm_g2_v6_br_shader = try createShaderModule(device, fns, spirv.MSM_G2_V6_BUCKET_REDUCE);
        errdefer fns.destroyShaderModule(device, msm_g2_v6_br_shader, null);
        const msm_g2_v6_wr_shader = try createShaderModule(device, fns, spirv.MSM_G2_V6_WINDOW_REDUCE);
        errdefer fns.destroyShaderModule(device, msm_g2_v6_wr_shader, null);

        // Create descriptor set layouts and pipeline layouts
        const msm_g1_v5_br_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        const msm_g1_v5_br_dsl = try createDescriptorSetLayout(device, fns, &msm_g1_v5_br_bindings);
        errdefer fns.destroyDescriptorSetLayout(device, msm_g1_v5_br_dsl, null);
        const msm_g1_v5_br_pl = try createPipelineLayout(device, fns, msm_g1_v5_br_dsl);
        errdefer fns.destroyPipelineLayout(device, msm_g1_v5_br_pl, null);
        const msm_g1_v5_br_pipeline = try createComputePipeline(device, fns, msm_g1_v5_br_shader, msm_g1_v5_br_pl);
        errdefer fns.destroyPipeline(device, msm_g1_v5_br_pipeline, null);

        const msm_g1_v5_wr_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        const msm_g1_v5_wr_dsl = try createDescriptorSetLayout(device, fns, &msm_g1_v5_wr_bindings);
        errdefer fns.destroyDescriptorSetLayout(device, msm_g1_v5_wr_dsl, null);
        const msm_g1_v5_wr_pl = try createPipelineLayout(device, fns, msm_g1_v5_wr_dsl);
        errdefer fns.destroyPipelineLayout(device, msm_g1_v5_wr_pl, null);
        const msm_g1_v5_wr_pipeline = try createComputePipeline(device, fns, msm_g1_v5_wr_shader, msm_g1_v5_wr_pl);
        errdefer fns.destroyPipeline(device, msm_g1_v5_wr_pipeline, null);

        const msm_g2_v6_br_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 7, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 8, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 9, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        const msm_g2_v6_br_dsl = try createDescriptorSetLayout(device, fns, &msm_g2_v6_br_bindings);
        errdefer fns.destroyDescriptorSetLayout(device, msm_g2_v6_br_dsl, null);
        const msm_g2_v6_br_pl = try createPipelineLayout(device, fns, msm_g2_v6_br_dsl);
        errdefer fns.destroyPipelineLayout(device, msm_g2_v6_br_pl, null);
        const msm_g2_v6_br_pipeline = try createComputePipeline(device, fns, msm_g2_v6_br_shader, msm_g2_v6_br_pl);
        errdefer fns.destroyPipeline(device, msm_g2_v6_br_pipeline, null);

        const msm_g2_v6_wr_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        const msm_g2_v6_wr_dsl = try createDescriptorSetLayout(device, fns, &msm_g2_v6_wr_bindings);
        errdefer fns.destroyDescriptorSetLayout(device, msm_g2_v6_wr_dsl, null);
        const msm_g2_v6_wr_pl = try createPipelineLayout(device, fns, msm_g2_v6_wr_dsl);
        errdefer fns.destroyPipelineLayout(device, msm_g2_v6_wr_pl, null);
        const msm_g2_v6_wr_pipeline = try createComputePipeline(device, fns, msm_g2_v6_wr_shader, msm_g2_v6_wr_pl);
        errdefer fns.destroyPipeline(device, msm_g2_v6_wr_pipeline, null);

        const pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 40,
        };
        const descriptor_pool_create_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 8,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var descriptor_pool: c.VkDescriptorPool = undefined;
        res = fns.createDescriptorPool(device, &descriptor_pool_create_info, null, &descriptor_pool);
        if (res != c.VK_SUCCESS) return error.DescriptorPoolCreationFailed;
        errdefer fns.destroyDescriptorPool(device, descriptor_pool, null);

        const command_pool_create_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = selected_queue_family,
        };
        var command_pool: c.VkCommandPool = undefined;
        res = fns.createCommandPool(device, &command_pool_create_info, null, &command_pool);
        if (res != c.VK_SUCCESS) return error.CommandPoolCreationFailed;
        errdefer fns.destroyCommandPool(device, command_pool, null);

        const fence_create_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        var fence: c.VkFence = undefined;
        res = fns.createFence(device, &fence_create_info, null, &fence);
        if (res != c.VK_SUCCESS) return error.FenceCreationFailed;
        errdefer fns.destroyFence(device, fence, null);

        var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
        fns.getPhysicalDeviceMemoryProperties(physical_device, &mem_props);

        const is_discrete = selected_props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
        const device_type: mod.GpuCapabilities.DeviceType = switch (selected_props.deviceType) {
            c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => .discrete,
            c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => .integrated,
            c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => .virtual,
            c.VK_PHYSICAL_DEVICE_TYPE_CPU => .cpu,
            else => .other,
        };

        const max_threads = selected_props.limits.maxComputeWorkGroupInvocations;
        const max_buffer = selected_props.limits.maxStorageBufferRange;

        var device_local_memory: u64 = 0;
        for (0..mem_props.memoryHeapCount) |i| {
            const heap = mem_props.memoryHeaps[i];
            if ((heap.flags & c.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                device_local_memory += heap.size;
            }
        }

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = max_threads,
            .max_buffer_size = max_buffer,
            .recommended_memory = device_local_memory,
            .is_discrete = is_discrete,
            .device_type = device_type,
        };

        const self = try allocator.create(Self);
        self.* = .{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .compute_queue = compute_queue,
            .compute_queue_family = selected_queue_family,
            .msm_g1_v5_br_pipeline = msm_g1_v5_br_pipeline,
            .msm_g1_v5_br_pipeline_layout = msm_g1_v5_br_pl,
            .msm_g1_v5_br_descriptor_set_layout = msm_g1_v5_br_dsl,
            .msm_g1_v5_br_shader_module = msm_g1_v5_br_shader,
            .msm_g1_v5_wr_pipeline = msm_g1_v5_wr_pipeline,
            .msm_g1_v5_wr_pipeline_layout = msm_g1_v5_wr_pl,
            .msm_g1_v5_wr_descriptor_set_layout = msm_g1_v5_wr_dsl,
            .msm_g1_v5_wr_shader_module = msm_g1_v5_wr_shader,
            .msm_g2_v6_br_pipeline = msm_g2_v6_br_pipeline,
            .msm_g2_v6_br_pipeline_layout = msm_g2_v6_br_pl,
            .msm_g2_v6_br_descriptor_set_layout = msm_g2_v6_br_dsl,
            .msm_g2_v6_br_shader_module = msm_g2_v6_br_shader,
            .msm_g2_v6_wr_pipeline = msm_g2_v6_wr_pipeline,
            .msm_g2_v6_wr_pipeline_layout = msm_g2_v6_wr_pl,
            .msm_g2_v6_wr_descriptor_set_layout = msm_g2_v6_wr_dsl,
            .msm_g2_v6_wr_shader_module = msm_g2_v6_wr_shader,
            .descriptor_pool = descriptor_pool,
            .command_pool = command_pool,
            .fence = fence,
            .mem_props = mem_props,
            .allocator = allocator,
            .fns = fns,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.fns.destroyFence(self.device, self.fence, null);
        self.fns.destroyCommandPool(self.device, self.command_pool, null);
        self.fns.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.fns.destroyPipeline(self.device, self.msm_g1_v5_br_pipeline, null);
        self.fns.destroyPipelineLayout(self.device, self.msm_g1_v5_br_pipeline_layout, null);
        self.fns.destroyDescriptorSetLayout(self.device, self.msm_g1_v5_br_descriptor_set_layout, null);
        self.fns.destroyShaderModule(self.device, self.msm_g1_v5_br_shader_module, null);
        self.fns.destroyPipeline(self.device, self.msm_g1_v5_wr_pipeline, null);
        self.fns.destroyPipelineLayout(self.device, self.msm_g1_v5_wr_pipeline_layout, null);
        self.fns.destroyDescriptorSetLayout(self.device, self.msm_g1_v5_wr_descriptor_set_layout, null);
        self.fns.destroyShaderModule(self.device, self.msm_g1_v5_wr_shader_module, null);
        self.fns.destroyPipeline(self.device, self.msm_g2_v6_br_pipeline, null);
        self.fns.destroyPipelineLayout(self.device, self.msm_g2_v6_br_pipeline_layout, null);
        self.fns.destroyDescriptorSetLayout(self.device, self.msm_g2_v6_br_descriptor_set_layout, null);
        self.fns.destroyShaderModule(self.device, self.msm_g2_v6_br_shader_module, null);
        self.fns.destroyPipeline(self.device, self.msm_g2_v6_wr_pipeline, null);
        self.fns.destroyPipelineLayout(self.device, self.msm_g2_v6_wr_pipeline_layout, null);
        self.fns.destroyDescriptorSetLayout(self.device, self.msm_g2_v6_wr_descriptor_set_layout, null);
        self.fns.destroyShaderModule(self.device, self.msm_g2_v6_wr_shader_module, null);
        self.fns.destroyDevice(self.device, null);
        self.fns.destroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createBuffer(self: *Self, size: c.VkDeviceSize) !BufferAllocation {
        const buffer_create_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: c.VkBuffer = undefined;
        var res = self.fns.createBuffer(self.device, &buffer_create_info, null, &buffer);
        if (res != c.VK_SUCCESS) return error.BufferCreationFailed;

        var mem_reqs: c.VkMemoryRequirements = undefined;
        self.fns.getBufferMemoryRequirements(self.device, buffer, &mem_reqs);

        const mem_type_index = findMemoryType(&self.mem_props, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoSuitableMemoryType;
        const mem_alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type_index,
        };
        var memory: c.VkDeviceMemory = undefined;
        res = self.fns.allocateMemory(self.device, &mem_alloc_info, null, &memory);
        if (res != c.VK_SUCCESS) return error.MemoryAllocationFailed;

        res = self.fns.bindBufferMemory(self.device, buffer, memory, 0);
        if (res != c.VK_SUCCESS) return error.MemoryBindFailed;

        var mapped: ?*anyopaque = null;
        res = self.fns.mapMemory(self.device, memory, 0, size, 0, &mapped);
        if (res != c.VK_SUCCESS) return error.MemoryMapFailed;

        return BufferAllocation{ .buffer = buffer, .memory = memory, .size = size, .mapped = mapped };
    }

    fn destroyBuffer(self: *Self, buf: BufferAllocation) void {
        self.fns.unmapMemory(self.device, buf.memory);
        self.fns.freeMemory(self.device, buf.memory, null);
        self.fns.destroyBuffer(self.device, buf.buffer, null);
    }

    fn allocateDescriptorSet(self: *Self, layout: c.VkDescriptorSetLayout) !c.VkDescriptorSet {
        const alloc_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        var descriptor_set: c.VkDescriptorSet = undefined;
        const res = self.fns.allocateDescriptorSets(self.device, &alloc_info, &descriptor_set);
        if (res != c.VK_SUCCESS) return error.DescriptorSetAllocationFailed;
        return descriptor_set;
    }

    fn updateBufferDescriptorSet(self: *Self, descriptor_set: c.VkDescriptorSet, binding: u32, buffer: c.VkBuffer, size: c.VkDeviceSize) void {
        const buffer_info = c.VkDescriptorBufferInfo{
            .buffer = buffer,
            .offset = 0,
            .range = size,
        };
        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };
        self.fns.updateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn dispatchCommand(self: *Self, pipeline: c.VkPipeline, pipeline_layout: c.VkPipelineLayout, descriptor_set: c.VkDescriptorSet, workgroups_x: u32, workgroups_y: u32, workgroups_z: u32) !void {
        const cmd_alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var command_buffer: c.VkCommandBuffer = undefined;
        var res = self.fns.allocateCommandBuffers(self.device, &cmd_alloc_info, &command_buffer);
        if (res != c.VK_SUCCESS) return error.CommandBufferAllocationFailed;
        defer self.fns.freeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        res = self.fns.beginCommandBuffer(command_buffer, &begin_info);
        if (res != c.VK_SUCCESS) return error.CommandBufferBeginFailed;

        self.fns.cmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        self.fns.cmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, &descriptor_set, 0, null);
        self.fns.cmdDispatch(command_buffer, workgroups_x, workgroups_y, workgroups_z);

        res = self.fns.endCommandBuffer(command_buffer);
        if (res != c.VK_SUCCESS) return error.CommandBufferEndFailed;

        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        res = self.fns.queueSubmit(self.compute_queue, 1, &submit_info, self.fence);
        if (res != c.VK_SUCCESS) return error.QueueSubmitFailed;

        res = self.fns.waitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64));
        if (res != c.VK_SUCCESS) return error.FenceWaitFailed;

        res = self.fns.resetFences(self.device, 1, &self.fence);
        if (res != c.VK_SUCCESS) return error.FenceResetFailed;
    }

    /// Perform MSM on G1 points using v5 sorted-bucket Pippenger.
    pub fn msmG1_v5(
        self: *Self,
        x_data: []const u8,
        y_data: []const u8,
        neg_y_data: []const u8,
        config: mod.MSMConfig,
        offsets: []const u32,
        sorted_indices: []const u32,
    ) ![]mod.G1Point {
        const num_windows = config.n_windows;
        const num_buckets = config.n_buckets;

        const x_buffer = try self.createBuffer(@intCast(x_data.len));
        defer self.destroyBuffer(x_buffer);
        const y_buffer = try self.createBuffer(@intCast(y_data.len));
        defer self.destroyBuffer(y_buffer);
        const neg_y_buffer = try self.createBuffer(@intCast(neg_y_data.len));
        defer self.destroyBuffer(neg_y_buffer);
        const config_buffer = try self.createBuffer(@sizeOf(mod.MSMConfig));
        defer self.destroyBuffer(config_buffer);
        const offsets_buffer = try self.createBuffer(@intCast(offsets.len * @sizeOf(u32)));
        defer self.destroyBuffer(offsets_buffer);
        const indices_buffer = try self.createBuffer(@intCast(sorted_indices.len * @sizeOf(u32)));
        defer self.destroyBuffer(indices_buffer);
        const bucket_sums_size = num_windows * num_buckets * @sizeOf(mod.G1Point);
        const bucket_sums_buffer = try self.createBuffer(@intCast(bucket_sums_size));
        defer self.destroyBuffer(bucket_sums_buffer);
        const result_size = num_windows * @sizeOf(mod.G1Point);
        const result_buffer = try self.createBuffer(@intCast(result_size));
        defer self.destroyBuffer(result_buffer);

        @memcpy(@as([*]u8, @ptrCast(x_buffer.mapped))[0..x_data.len], x_data);
        @memcpy(@as([*]u8, @ptrCast(y_buffer.mapped))[0..y_data.len], y_data);
        @memcpy(@as([*]u8, @ptrCast(neg_y_buffer.mapped))[0..neg_y_data.len], neg_y_data);
        @as(*mod.MSMConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = config;
        @memcpy(@as([*]u8, @ptrCast(offsets_buffer.mapped))[0..offsets.len * @sizeOf(u32)], std.mem.sliceAsBytes(offsets));
        @memcpy(@as([*]u8, @ptrCast(indices_buffer.mapped))[0..sorted_indices.len * @sizeOf(u32)], std.mem.sliceAsBytes(sorted_indices));

        // Pass 1: Bucket reduce
        const br_descriptor_set = try self.allocateDescriptorSet(self.msm_g1_v5_br_descriptor_set_layout);
        self.updateBufferDescriptorSet(br_descriptor_set, 0, x_buffer.buffer, x_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 1, y_buffer.buffer, y_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 2, neg_y_buffer.buffer, neg_y_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 3, config_buffer.buffer, config_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 4, offsets_buffer.buffer, offsets_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 5, indices_buffer.buffer, indices_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 6, bucket_sums_buffer.buffer, bucket_sums_buffer.size);

        const total_threads = num_windows * num_buckets * 64;
        const workgroups_x: u32 = @intCast(@max(1, total_threads / 64));
        try self.dispatchCommand(self.msm_g1_v5_br_pipeline, self.msm_g1_v5_br_pipeline_layout, br_descriptor_set, workgroups_x, 1, 1);

        // Pass 2: Window reduce
        const wr_descriptor_set = try self.allocateDescriptorSet(self.msm_g1_v5_wr_descriptor_set_layout);
        self.updateBufferDescriptorSet(wr_descriptor_set, 0, bucket_sums_buffer.buffer, bucket_sums_buffer.size);
        self.updateBufferDescriptorSet(wr_descriptor_set, 1, result_buffer.buffer, result_buffer.size);

        try self.dispatchCommand(self.msm_g1_v5_wr_pipeline, self.msm_g1_v5_wr_pipeline_layout, wr_descriptor_set, num_windows, 1, 1);

        const results = try self.allocator.alloc(mod.G1Point, num_windows);
        @memcpy(std.mem.sliceAsBytes(results), @as([*]u8, @ptrCast(result_buffer.mapped))[0..result_size]);
        return results;
    }

    /// Perform MSM on G2 points using v6 sorted-bucket Pippenger.
    pub fn msmG2_v6(
        self: *Self,
        x_c0: []const u8,
        x_c1: []const u8,
        y_c0: []const u8,
        y_c1: []const u8,
        neg_y_c0: []const u8,
        neg_y_c1: []const u8,
        config: mod.MSMConfig,
        offsets: []const u32,
        sorted_indices: []const u32,
    ) ![]mod.G2Point {
        const num_windows = config.n_windows;
        const num_buckets: usize = @intCast(config.n_buckets);

        const x_c0_buffer = try self.createBuffer(@intCast(x_c0.len));
        defer self.destroyBuffer(x_c0_buffer);
        const x_c1_buffer = try self.createBuffer(@intCast(x_c1.len));
        defer self.destroyBuffer(x_c1_buffer);
        const y_c0_buffer = try self.createBuffer(@intCast(y_c0.len));
        defer self.destroyBuffer(y_c0_buffer);
        const y_c1_buffer = try self.createBuffer(@intCast(y_c1.len));
        defer self.destroyBuffer(y_c1_buffer);
        const config_buffer = try self.createBuffer(@sizeOf(mod.MSMConfig));
        defer self.destroyBuffer(config_buffer);
        const offsets_buffer = try self.createBuffer(@intCast(offsets.len * @sizeOf(u32)));
        defer self.destroyBuffer(offsets_buffer);
        const indices_buffer = try self.createBuffer(@intCast(sorted_indices.len * @sizeOf(u32)));
        defer self.destroyBuffer(indices_buffer);
        const bucket_sums_size = num_windows * num_buckets * @sizeOf(mod.G2Point);
        const bucket_sums_buffer = try self.createBuffer(@intCast(bucket_sums_size));
        defer self.destroyBuffer(bucket_sums_buffer);
        const neg_y_c0_buffer = try self.createBuffer(@intCast(neg_y_c0.len));
        defer self.destroyBuffer(neg_y_c0_buffer);
        const neg_y_c1_buffer = try self.createBuffer(@intCast(neg_y_c1.len));
        defer self.destroyBuffer(neg_y_c1_buffer);
        const result_size = num_windows * @sizeOf(mod.G2Point);
        const result_buffer = try self.createBuffer(@intCast(result_size));
        defer self.destroyBuffer(result_buffer);

        @memcpy(@as([*]u8, @ptrCast(x_c0_buffer.mapped))[0..x_c0.len], x_c0);
        @memcpy(@as([*]u8, @ptrCast(x_c1_buffer.mapped))[0..x_c1.len], x_c1);
        @memcpy(@as([*]u8, @ptrCast(y_c0_buffer.mapped))[0..y_c0.len], y_c0);
        @memcpy(@as([*]u8, @ptrCast(y_c1_buffer.mapped))[0..y_c1.len], y_c1);
        @as(*mod.MSMConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = config;
        @memcpy(@as([*]u8, @ptrCast(offsets_buffer.mapped))[0..offsets.len * @sizeOf(u32)], std.mem.sliceAsBytes(offsets));
        @memcpy(@as([*]u8, @ptrCast(indices_buffer.mapped))[0..sorted_indices.len * @sizeOf(u32)], std.mem.sliceAsBytes(sorted_indices));
        @memcpy(@as([*]u8, @ptrCast(neg_y_c0_buffer.mapped))[0..neg_y_c0.len], neg_y_c0);
        @memcpy(@as([*]u8, @ptrCast(neg_y_c1_buffer.mapped))[0..neg_y_c1.len], neg_y_c1);

        // Pass 1: Bucket reduce
        const br_descriptor_set = try self.allocateDescriptorSet(self.msm_g2_v6_br_descriptor_set_layout);
        self.updateBufferDescriptorSet(br_descriptor_set, 0, x_c0_buffer.buffer, x_c0_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 1, x_c1_buffer.buffer, x_c1_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 2, y_c0_buffer.buffer, y_c0_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 3, y_c1_buffer.buffer, y_c1_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 4, config_buffer.buffer, config_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 5, offsets_buffer.buffer, offsets_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 6, indices_buffer.buffer, indices_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 7, bucket_sums_buffer.buffer, bucket_sums_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 8, neg_y_c0_buffer.buffer, neg_y_c0_buffer.size);
        self.updateBufferDescriptorSet(br_descriptor_set, 9, neg_y_c1_buffer.buffer, neg_y_c1_buffer.size);

        const total_threads = num_windows * num_buckets * 64;
        const workgroups_x: u32 = @intCast(@max(1, total_threads / 64));
        try self.dispatchCommand(self.msm_g2_v6_br_pipeline, self.msm_g2_v6_br_pipeline_layout, br_descriptor_set, workgroups_x, 1, 1);

        // Pass 2: Window reduce
        const wr_descriptor_set = try self.allocateDescriptorSet(self.msm_g2_v6_wr_descriptor_set_layout);
        self.updateBufferDescriptorSet(wr_descriptor_set, 0, bucket_sums_buffer.buffer, bucket_sums_buffer.size);
        self.updateBufferDescriptorSet(wr_descriptor_set, 1, config_buffer.buffer, config_buffer.size);
        self.updateBufferDescriptorSet(wr_descriptor_set, 2, result_buffer.buffer, result_buffer.size);

        try self.dispatchCommand(self.msm_g2_v6_wr_pipeline, self.msm_g2_v6_wr_pipeline_layout, wr_descriptor_set, num_windows, 1, 1);

        const results = try self.allocator.alloc(mod.G2Point, num_windows);
        @memcpy(std.mem.sliceAsBytes(results), @as([*]u8, @ptrCast(result_buffer.mapped))[0..result_size]);
        return results;
    }

    /// Perform in-place FFT on Fr elements. (Stub — needs FFT SPIR-V)
    pub fn fftFr(
        self: *Self,
        data: []const u8,
        twiddles: []const u8,
        inverse_n: []const u8,
        log_n: u32,
    ) !void {
        _ = self;
        _ = data;
        _ = twiddles;
        _ = inverse_n;
        _ = log_n;
        return error.NotImplemented;
    }
};

/// Accumulate G1 window results into a single point.
/// Mirrors metal.accumulateG1.
pub fn accumulateG1(windows: []const mod.G1Point) cpu.curve.G1Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g1_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g1_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G1Point{
            .x = mod_pt.x,
            .y = mod_pt.y,
            .zz = mod_pt.zz,
            .zzz = mod_pt.zzz,
        };
        result = cpu.curve.g1_add(result, win_point);
    }
    return result;
}

/// Accumulate G2 window results into a single point.
/// Mirrors metal.accumulateG2.
pub fn accumulateG2(windows: []const mod.G2Point) cpu.curve.G2Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g2_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g2_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G2Point{
            .x = .{ .a = mod_pt.x[0..4].*, .b = mod_pt.x[4..8].* },
            .y = .{ .a = mod_pt.y[0..4].*, .b = mod_pt.y[4..8].* },
            .zz = .{ .a = mod_pt.zz[0..4].*, .b = mod_pt.zz[4..8].* },
            .zzz = .{ .a = mod_pt.zzz[0..4].*, .b = mod_pt.zzz[4..8].* },
        };
        result = cpu.curve.g2_add(result, win_point);
    }
    return result;
}

fn findMemoryType(mem_props: *const c.VkPhysicalDeviceMemoryProperties, type_filter: u32, properties: c.VkMemoryPropertyFlags) ?u32 {
    for (0..mem_props.memoryTypeCount) |i| {
        const idx: u5 = @intCast(i);
        if ((type_filter & (@as(u32, 1) << idx)) != 0) {
            const mem_type = mem_props.memoryTypes[i];
            if ((mem_type.propertyFlags & properties) == properties) return @intCast(i);
        }
    }
    return null;
}
