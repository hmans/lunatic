-- game/main.lua — PBR test with MetalRoughSpheres
-- Swap to DamagedHelmet.glb or your own model to test

-- Setup
lunatic.set_clear_color(0.3, 0.3, 0.35)
lunatic.set_ambient(0.1, 0.1, 0.12)
lunatic.set_fog(false)

-- Directional light
local light = lunatic.spawn()
lunatic.add(light, "directional_light", 0.3, 0.8, 0.5, 1, 1, 1)

-- Load MetalRoughSpheres test model
local model = lunatic.load_gltf("assets/MetalRoughSpheres.glb")

-- Spawn all primitives from the model
for i, mesh_id in ipairs(model.meshes) do
  local e = lunatic.spawn()
  lunatic.add(e, "position", 0, 0, 0)
  lunatic.add(e, "rotation", 0, 0, 0)
  lunatic.add(e, "mesh", mesh_id)
  local mat_id = model.materials[i] or model.materials[1]
  if mat_id then
    lunatic.add(e, "material", mat_id)
  end
end

-- Camera looking at the grid
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 0, 25)
lunatic.add(cam, "rotation", 0, 0, 0)
lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1)
