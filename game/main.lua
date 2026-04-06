-- Game entry point
-- Set up your scene, register systems, and define game logic here.

-- Scene settings
lunatic.set_clear_color(0.1, 0.1, 0.15)
lunatic.set_ambient(0.2, 0.2, 0.25)

-- Camera
local cam = lunatic.spawn()
lunatic.add(cam, "position", 0, 5, 10)
lunatic.add(cam, "rotation", 25, 0, 0)
lunatic.add(cam, "camera")
lunatic.add(cam, "fly_camera")
