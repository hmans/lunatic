// C wrapper for ImGui SDL3 + SDL_GPU backends.
// Allows Zig to @cImport these alongside cimgui.h and SDL3.

#pragma once
#include "cimgui.h"
#include <SDL3/SDL_gpu.h>

#ifdef __cplusplus
extern "C" {
#endif

// SDL3 platform backend
bool cImGui_ImplSDL3_InitForSDLGPU(SDL_Window* window);
void cImGui_ImplSDL3_Shutdown(void);
void cImGui_ImplSDL3_NewFrame(void);
bool cImGui_ImplSDL3_ProcessEvent(const SDL_Event* event);

// SDL_GPU renderer backend
typedef struct {
    SDL_GPUDevice*              Device;
    SDL_GPUTextureFormat        ColorTargetFormat;
    SDL_GPUSampleCount          MSAASamples;
} cImGui_ImplSDLGPU3_InitInfo;

bool cImGui_ImplSDLGPU3_Init(cImGui_ImplSDLGPU3_InitInfo* info);
void cImGui_ImplSDLGPU3_Shutdown(void);
void cImGui_ImplSDLGPU3_NewFrame(void);
void cImGui_ImplSDLGPU3_PrepareDrawData(ImDrawData* draw_data, SDL_GPUCommandBuffer* command_buffer);
void cImGui_ImplSDLGPU3_RenderDrawData(ImDrawData* draw_data, SDL_GPUCommandBuffer* command_buffer, SDL_GPURenderPass* render_pass);

#ifdef __cplusplus
}
#endif
