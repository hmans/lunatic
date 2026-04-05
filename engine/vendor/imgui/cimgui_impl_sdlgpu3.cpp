// C wrapper implementation for ImGui SDL3 + SDL_GPU backends.
// NOTE: Do NOT include cimgui.h here — it conflicts with imgui.h in C++ mode.
// The C header (cimgui_impl_sdlgpu3.h) is only for Zig's @cImport.

#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlgpu3.h"

// Mirror of the C-side struct (must match cimgui_impl_sdlgpu3.h)
struct cImGui_ImplSDLGPU3_InitInfo {
    SDL_GPUDevice*              Device;
    SDL_GPUTextureFormat        ColorTargetFormat;
    SDL_GPUSampleCount          MSAASamples;
};

extern "C" {

// SDL3 platform backend
bool cImGui_ImplSDL3_InitForSDLGPU(SDL_Window* window) {
    return ImGui_ImplSDL3_InitForSDLGPU(window);
}

void cImGui_ImplSDL3_Shutdown(void) {
    ImGui_ImplSDL3_Shutdown();
}

void cImGui_ImplSDL3_NewFrame(void) {
    ImGui_ImplSDL3_NewFrame();
}

bool cImGui_ImplSDL3_ProcessEvent(const SDL_Event* event) {
    return ImGui_ImplSDL3_ProcessEvent(event);
}

// SDL_GPU renderer backend
bool cImGui_ImplSDLGPU3_Init(cImGui_ImplSDLGPU3_InitInfo* info) {
    ImGui_ImplSDLGPU3_InitInfo cpp_info = {};
    cpp_info.Device = info->Device;
    cpp_info.ColorTargetFormat = info->ColorTargetFormat;
    cpp_info.MSAASamples = info->MSAASamples;
    return ImGui_ImplSDLGPU3_Init(&cpp_info);
}

void cImGui_ImplSDLGPU3_Shutdown(void) {
    ImGui_ImplSDLGPU3_Shutdown();
}

void cImGui_ImplSDLGPU3_NewFrame(void) {
    ImGui_ImplSDLGPU3_NewFrame();
}

void cImGui_ImplSDLGPU3_PrepareDrawData(ImDrawData* draw_data, SDL_GPUCommandBuffer* command_buffer) {
    ImGui_ImplSDLGPU3_PrepareDrawData(draw_data, command_buffer);
}

void cImGui_ImplSDLGPU3_RenderDrawData(ImDrawData* draw_data, SDL_GPUCommandBuffer* command_buffer, SDL_GPURenderPass* render_pass) {
    ImGui_ImplSDLGPU3_RenderDrawData(draw_data, command_buffer, render_pass, nullptr);
}

} // extern "C"
