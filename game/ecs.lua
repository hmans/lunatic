-- ecs.lua — minimal Entity Component System
--
-- Usage:
--   local ecs = require("ecs")
--   local world = ecs.world()
--
--   local e = world:spawn()
--   world:set(e, "position", { x = 0, y = 0, z = 0 })
--   world:set(e, "velocity", { x = 1, y = 0, z = 0 })
--
--   -- Query entities that have all listed components:
--   for entity, pos, vel in world:query("position", "velocity") do
--     pos.x = pos.x + vel.x * dt
--   end
--
--   world:despawn(e)

local ecs = {}

function ecs.world()
  local self = {}
  local next_id = 1
  local entities = {}       -- set of living entity ids
  local components = {}     -- components[name][entity] = data

  --- Spawn a new entity. Optionally pass a table of components.
  --- e.g. world:spawn({ position = {x=0,y=0,z=0}, mesh = "cube" })
  function self:spawn(init)
    local id = next_id
    next_id = next_id + 1
    entities[id] = true

    if init then
      for name, value in pairs(init) do
        self:set(id, name, value)
      end
    end

    return id
  end

  --- Remove an entity and all its components.
  function self:despawn(id)
    entities[id] = nil
    for _, store in pairs(components) do
      store[id] = nil
    end
  end

  --- Set a component on an entity.
  function self:set(id, name, value)
    if not components[name] then
      components[name] = {}
    end
    components[name][id] = value
  end

  --- Get a component from an entity (or nil).
  function self:get(id, name)
    local store = components[name]
    return store and store[id]
  end

  --- Remove a component from an entity.
  function self:remove(id, name)
    local store = components[name]
    if store then store[id] = nil end
  end

  --- Query entities that have ALL of the listed components.
  --- Returns an iterator: for entity, comp1, comp2, ... in world:query("a", "b")
  function self:query(...)
    local names = { ... }
    local n = #names

    -- Grab component stores, find the smallest one to iterate
    local stores = {}
    local smallest_store = nil
    local smallest_size = math.huge
    for i = 1, n do
      local store = components[names[i]]
      if not store then
        -- One of the requested components has never been used;
        -- no entity can match, return empty iterator.
        return function() end
      end
      stores[i] = store

      local size = 0
      for _ in pairs(store) do size = size + 1 end
      if size < smallest_size then
        smallest_size = size
        smallest_store = store
      end
    end

    -- Iterator state
    local iter_key = nil
    local results = {}

    return function()
      while true do
        iter_key = next(smallest_store, iter_key)
        if iter_key == nil then return nil end

        -- Check that this entity has ALL components
        local match = true
        for i = 1, n do
          local val = stores[i][iter_key]
          if val == nil then
            match = false
            break
          end
          results[i] = val
        end

        if match then
          return iter_key, unpack(results, 1, n)
        end
      end
    end
  end

  return self
end

return ecs
