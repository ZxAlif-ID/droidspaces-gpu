cmake_minimum_required(VERSION 3.16)
project(gpu-demo C)

# The demo links only the Vulkan loader (libvulkan.so.1 from apt, which is
# driver-independent). The DRIVER is chosen at runtime via VK_ICD_FILENAMES.
find_library(VULKAN_LIBRARY NAMES vulkan vulkan.so.1 REQUIRED)

add_executable(gpu-demo gpu_demo.c shader_spv.h)
target_link_libraries(gpu-demo PRIVATE ${VULKAN_LIBRARY})
target_compile_options(gpu-demo PRIVATE -O2 -Wall -Wextra)
