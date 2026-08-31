local Util = {}

function Util.copy_position(position)
  if not position then return nil end
  return {x = position.x, y = position.y}
end

function Util.distance(first, second)
  local dx = first.x - second.x
  local dy = first.y - second.y
  return math.sqrt(dx * dx + dy * dy)
end

function Util.copy_path(path)
  local copy = {}
  for _, point in ipairs(path or {}) do
    copy[#copy + 1] = Util.copy_position(point)
  end
  return copy
end

function Util.value_at_path(root, path)
  local value = root
  for segment in string.gmatch(path, "[^.]+") do
    if type(value) ~= "table" then return nil end
    value = value[segment]
  end
  return value
end

function Util.append_bounded(list, value, limit)
  list[#list + 1] = value
  if #list > limit then table.remove(list, 1) end
end

return Util
