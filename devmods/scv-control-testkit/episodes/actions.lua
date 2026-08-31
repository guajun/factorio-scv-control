local Actions = {}
local handlers = {}

local function each_line_position(line, callback)
  local dx = line.to.x == line.from.x and 0 or (line.to.x > line.from.x and 1 or -1)
  local dy = line.to.y == line.from.y and 0 or (line.to.y > line.from.y and 1 or -1)
  local x = line.from.x
  local y = line.from.y
  while true do
    callback({x = x, y = y})
    if x == line.to.x and y == line.to.y then break end
    x = x + dx
    y = y + dy
  end
end

local function create_entity(surface, specification)
  local entity = surface.create_entity(specification)
  if entity then
    entity.destructible = false
    entity.minable = false
  end
  return entity
end

handlers["create-wall-line"] = function(spec, context)
  local positions = {}
  local created = 0
  each_line_position(spec, function(position)
    local entity = create_entity(context.surface, {
      name = "stone-wall",
      position = position,
      force = spec.force or "neutral"
    })
    if entity then
      created = created + 1
      positions[#positions + 1] = position
    end
  end)
  return {
    status = created > 0 and "applied" or "failed",
    created_entities = created,
    obstacle_positions = spec.obstacle and positions or nil,
    revision_tick = false
  }
end

handlers["create-entities"] = function(spec, context)
  local created = 0
  local positions = {}
  for _, entity_spec in ipairs(spec.entities or {}) do
    local entity = create_entity(context.surface, entity_spec)
    if entity then
      created = created + 1
      positions[#positions + 1] = {x = entity.position.x, y = entity.position.y}
    end
  end
  return {
    status = created == #(spec.entities or {}) and "applied" or "failed",
    created_entities = created,
    obstacle_positions = spec.obstacle and positions or nil,
    revision_tick = false
  }
end

function Actions.execute(spec, context, extensions)
  local handler = extensions and extensions[spec.type] or handlers[spec.type]
  if not handler then error("unknown episode action: " .. tostring(spec.type)) end
  return handler(spec, context)
end

Actions.each_line_position = each_line_position
Actions.create_entity = create_entity

return Actions
