-- Lunatic — scene manager and shared debug UI
--
-- Right-click + drag to look around, WASD to move, Space/Ctrl for up/down.
-- Shift for fast movement. Use the Debug window to switch scenes and tweak
-- post-processing settings.

--------------------------------------------------------------------------------
-- Scenes
--------------------------------------------------------------------------------

local scenes = {
  require("scenes.physics_rain"),
  require("scenes.lighting_gallery"),
  require("scenes.material_showcase"),
}

local current_scene = 0  -- 0 = none loaded yet
local scene_cleanup = nil

--------------------------------------------------------------------------------
-- Camera (shared across all scenes)
--------------------------------------------------------------------------------

local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 8, 12)
lunatic.add(cam, "rotation", 34, 0, 0)
lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1,
  0.8,   -- exposure
  0.5,   -- bloom_intensity
  0,     -- dof_focus_dist (0 = disabled)
  8,     -- dof_focus_range
  8,     -- dof_blur_radius
  0.4,   -- vignette
  0.5,   -- vignette_smoothness
  0.08,  -- chromatic_aberration
  0.03,  -- grain
  0.0,   -- color_temp
  0.15,  -- flare_intensity
  0.37,  -- flare_ghost_dispersal
  0.5,   -- flare_halo_width
  0.005, -- flare_chroma_distortion
  0.5    -- flare_dirt_intensity
)
lunatic.add(cam, "fly_camera")

--------------------------------------------------------------------------------
-- Scene switching
--------------------------------------------------------------------------------

local function load_scene(index)
  -- Cleanup previous scene
  if scene_cleanup then
    scene_cleanup()
    scene_cleanup = nil
  end

  current_scene = index
  scene_cleanup = scenes[index].setup(cam)
end

-- Load the first scene
load_scene(1)

--------------------------------------------------------------------------------
-- Debug UI (shared)
--------------------------------------------------------------------------------

lunatic.system("debug_ui", function(dt)
  ui.set_next_window_pos(16, 16, "first_use")
  ui.set_next_window_size(280, 0, "first_use")
  ui.begin_window("Debug")

  -- Scene selector
  ui.separator_text("Scene")
  for i, scene in ipairs(scenes) do
    local label = scene.name
    if i == current_scene then label = "> " .. label end
    if ui.button(label .. "##scene" .. i) and i ~= current_scene then
      load_scene(i)
    end
  end

  -- Post-processing
  if ui.collapsing_header("Post-Processing") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.exposure = ui.slider_float("Exposure", cam_ref.exposure, 0.1, 5.0)
    cam_ref.bloom_intensity = ui.slider_float("Bloom Intensity", cam_ref.bloom_intensity, 0.0, 1.0)
  end

  if ui.collapsing_header("Depth of Field") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.dof_focus_dist = ui.slider_float("Focus Distance", cam_ref.dof_focus_dist, 0, 50)
    cam_ref.dof_focus_range = ui.slider_float("Focus Range", cam_ref.dof_focus_range, 0.5, 30)
    cam_ref.dof_blur_radius = ui.slider_float("Blur Radius", cam_ref.dof_blur_radius, 1, 20)
  end

  if ui.collapsing_header("Lens Effects") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.vignette = ui.slider_float("Vignette", cam_ref.vignette, 0, 1)
    cam_ref.vignette_smoothness = ui.slider_float("Vignette Smoothness", cam_ref.vignette_smoothness, 0.2, 0.8)
    cam_ref.chromatic_aberration = ui.slider_float("Chromatic Aberration", cam_ref.chromatic_aberration, 0, 3)
    cam_ref.grain = ui.slider_float("Film Grain", cam_ref.grain, 0, 0.2)
    cam_ref.color_temp = ui.slider_float("Color Temperature", cam_ref.color_temp, -3, 3)
  end

  if ui.collapsing_header("Lens Flare") then
    local cam_ref = lunatic.ref(cam, "camera")
    cam_ref.flare_intensity = ui.slider_float("Flare Intensity", cam_ref.flare_intensity, 0, 3)
    cam_ref.flare_ghost_dispersal = ui.slider_float("Ghost Dispersal", cam_ref.flare_ghost_dispersal, 0.1, 1.0)
    cam_ref.flare_halo_width = ui.slider_float("Halo Width", cam_ref.flare_halo_width, 0.1, 0.9)
    cam_ref.flare_chroma_distortion = ui.slider_float("Chroma Distortion", cam_ref.flare_chroma_distortion, 0, 0.02)
    cam_ref.flare_dirt_intensity = ui.slider_float("Lens Dirt", cam_ref.flare_dirt_intensity, 0, 1)
  end

  if ui.collapsing_header("Bloom Shape") then
    local r = lunatic.get_bloom_radius()
    lunatic.set_bloom_radius(ui.slider_float("Radius", r, 0.5, 3.0))

    local t1, t2, t3, t4, t5, t6 = lunatic.get_bloom_tints()
    t1 = ui.slider_float("1/2 (core)", t1, 0, 1)
    t2 = ui.slider_float("1/4", t2, 0, 1)
    t3 = ui.slider_float("1/8", t3, 0, 1)
    t4 = ui.slider_float("1/16", t4, 0, 1)
    t5 = ui.slider_float("1/32", t5, 0, 1)
    t6 = ui.slider_float("1/64 (haze)", t6, 0, 1)
    lunatic.set_bloom_tints(t1, t2, t3, t4, t5, t6)
  end

  ui.end_window()
end)
