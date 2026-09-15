local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")

-- helpers.table_to_json rounds some binary64 values (e.g. 0.15 * 1.5) to a
-- neighboring representable value. Interchange identity must preserve all bits.
-- Factorio's patched %.17g also rounds. Generate the exact decimal expansion by
-- integer arithmetic; do not depend on runtime printf or tostring for numbers.
-- Empty plain Lua containers emit {}, matching scv-c14n1's empty equivalence.
local WireJson = {version = "scv-json-binary64/1"}
local MAX_BYTES = 32 * 1024 * 1024
local escaped = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}

local function quoted(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    return escaped[character] or string.format("\\u%04x", character:byte())
  end) .. '"'
end

local function exact_decimal(value)
  if value == 0 then return "0" end
  local negative = value < 0
  if negative then value = -value end
  local mantissa, exponent = math.frexp(value)
  mantissa, exponent = mantissa * 9007199254740992, exponent - 53
  while mantissa % 2 == 0 do mantissa, exponent = mantissa / 2, exponent + 1 end
  local limbs, base = {}, 10000000
  while mantissa > 0 do
    local quotient = math.floor(mantissa / base)
    limbs[#limbs + 1], mantissa = mantissa - quotient * base, quotient
  end
  -- m * 2^-k == (m * 5^k) * 10^-k. Products stay below 5e7,
  -- and are exact in Factorio's binary64-only Lua number representation.
  local multiplier = exponent < 0 and 5 or 2
  for _ = 1, math.abs(exponent) do
    local carry = 0
    for index = 1, #limbs do
      local product = limbs[index] * multiplier + carry
      carry = math.floor(product / base)
      limbs[index] = product - carry * base
    end
    if carry > 0 then limbs[#limbs + 1] = carry end
  end
  local pieces = {Canonical.integer_text(limbs[#limbs])}
  for index = #limbs - 1, 1, -1 do
    local part = Canonical.integer_text(limbs[index])
    pieces[#pieces + 1] = string.rep("0", 7 - #part) .. part
  end
  local digits = table.concat(pieces)
  if exponent < 0 then
    local split = #digits + exponent
    if split <= 0 then digits = "0." .. string.rep("0", -split) .. digits
    else digits = digits:sub(1, split) .. "." .. digits:sub(split + 1) end
  end
  return (negative and "-" or "") .. digits
end

function WireJson.encode(value)
  -- A bundle can contain several individually bounded snapshot/query values;
  -- its envelope therefore has a separate 32 MiB/four-million-value bound.
  local pieces, bytes, values, ancestors = {}, 0, 0, {}
  local string_cache, number_cache = {}, {}
  local function invalid(code, message)
    error({code = code, path = "$", message = message}, 0)
  end
  local function append(piece)
    bytes = bytes + #piece
    if bytes > MAX_BYTES then error({code = "wire-json-size-limit", path = "$",
      message = "Encoded interchange JSON exceeds 32 MiB."}, 0) end
    pieces[#pieces + 1] = piece
  end
  local encode
  encode = function(item, depth)
    values = values + 1
    if depth > 64 or values > 4000000 then invalid("wire-json-structure-limit", "JSON nesting/value limit exceeded.") end
    local kind = type(item)
    if kind == "nil" then append("null")
    elseif kind == "boolean" then append(item and "true" or "false")
    elseif kind == "number" then
      if item ~= item or math.abs(item) == math.huge then invalid("non-finite-number", "JSON numbers must be finite.") end
      local encoded = number_cache[item]
      if not encoded then
        encoded = exact_decimal(item)
        number_cache[item] = encoded
      end
      append(encoded)
    elseif kind == "string" then
      local encoded = string_cache[item]
      if not encoded then
        if not Canonical.valid_utf8(item) then invalid("invalid-utf8", "JSON strings must contain valid UTF-8.") end
        encoded = quoted(item)
        string_cache[item] = encoded
      end
      append(encoded)
    else
      if kind ~= "table" then invalid("unsupported-value-type", "JSON values must be plain values.") end
      if getmetatable(item) ~= nil then invalid("table-has-metatable", "JSON tables must be plain.") end
      if ancestors[item] then invalid("cyclic-table", "JSON tables cannot contain cycles.") end
      local keys, key_kind, maximum, length = {}, nil, 0, 0
      for key in pairs(item) do
        local current = type(key)
        if current ~= "string" and (current ~= "number" or key < 1 or key % 1 ~= 0) then
          invalid("unsupported-table-key", "JSON object keys must be strings; array keys positive integers.")
        end
        if key_kind and current ~= key_kind then invalid("mixed-table-keys", "Mixed-key JSON tables are unsupported.") end
        key_kind = current
        length = length + 1
        if current == "string" then keys[#keys + 1] = key
        elseif key > maximum then maximum = key end
      end
      if length == 0 then append("{}"); return end
      if key_kind == "number" then
        if maximum ~= length then invalid("sparse-array", "JSON arrays must be contiguous.") end
      else
        table.sort(keys)
      end
      ancestors[item] = true
      append(key_kind == "number" and "[" or "{")
      for index = 1, length do
        local key = key_kind == "number" and index or keys[index]
        if index > 1 then append(",") end
        if key_kind == "string" then encode(key, depth + 1); append(":") end
        encode(item[key], depth + 1)
      end
      append(key_kind == "number" and "]" or "}")
      ancestors[item] = nil
    end
  end
  local ok, encoding_error = pcall(encode, value, 0)
  if not ok then return nil, encoding_error end
  return table.concat(pieces)
end

return WireJson
