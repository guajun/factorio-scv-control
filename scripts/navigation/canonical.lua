-- scv-c14n1 is a deterministic value encoding, not JSON text canonicalization.
-- Numbers encode the exact binary64 value as odd integer mantissa * 2^exponent.
-- Empty objects/arrays share e; because plain Lua tables cannot distinguish them.
-- Grammar (UTF-8 bytes, no separators beyond these productions):
-- nil z; | boolean b0;/b1; | number n<odd mantissa>p<exponent>; (zero n0p0;)
-- string s<byte length>:<raw bytes> | empty container e;
-- array a<count>:<values in index order> | object o<count>:<string key,value>...
-- Nonempty object keys sort by unsigned UTF-8 bytes. Mixed/sparse tables reject.
-- Hash is scv-c14n1-adler32:<8 lowercase hex digits>:<encoded byte length>.
-- Adler32 + byte length is an accidental-corruption/content key, NOT a security
-- digest. Callers must still compare identities and validate received values.
local Canonical = {version = "scv-c14n1-adler32"}

local MAX_DEPTH = 64
local MAX_VALUES = 1000000
local MAX_BYTES = 8 * 1024 * 1024

local function failure(code, path, message)
  return nil, {code = code, path = path, message = message}
end

local function valid_utf8(value)
  if not value:find("[\128-\255]") then return true end
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    local length, minimum, maximum = 1, 128, 191
    if first <= 127 then
      length = 1
    elseif first >= 194 and first <= 223 then
      length = 2
    elseif first >= 224 and first <= 239 then
      length = 3
      if first == 224 then minimum = 160 end
      if first == 237 then maximum = 159 end
    elseif first >= 240 and first <= 244 then
      length = 4
      if first == 240 then minimum = 144 end
      if first == 244 then maximum = 143 end
    else
      return false
    end
    if length > 1 then
      local second = value:byte(index + 1)
      if not second or second < minimum or second > maximum then return false end
      for offset = 2, length - 1 do
        local next_byte = value:byte(index + offset)
        if not next_byte or next_byte < 128 or next_byte > 191 then return false end
      end
    end
    index = index + length
  end
  return true
end

-- The wire encoder shares validation without allocating a canonical traversal
-- for every string in a multi-snapshot artifact.
Canonical.valid_utf8 = valid_utf8

-- Factorio's patched printf/trio may round even %.0f on 16-digit integers.
-- Extract decimal digits using exact integer arithmetic instead of formatting.
local function integer_text(value)
  if value == 0 then return "0" end
  local negative = value < 0
  if negative then value = -value end
  local digits = {}
  while value > 0 do
    local quotient = math.floor(value / 10)
    local digit = value - quotient * 10
    digits[#digits + 1] = string.char(48 + digit)
    value = quotient
  end
  local result = {}
  if negative then result[1] = "-" end
  for index = #digits, 1, -1 do result[#result + 1] = digits[index] end
  return table.concat(result)
end

Canonical.integer_text = integer_text

local function number_text(value)
  if value == 0 then return "n0p0;" end
  local mantissa, exponent = math.frexp(value)
  mantissa, exponent = mantissa * 9007199254740992, exponent - 53
  while mantissa % 2 == 0 do
    mantissa, exponent = mantissa / 2, exponent + 1
  end
  return "n" .. integer_text(mantissa) .. "p" .. integer_text(exponent) .. ";"
end

local function ordered_key(first, second)
  if type(first) == "number" then return first < second end
  for index = 1, math.min(#first, #second) do
    local left, right = first:byte(index), second:byte(index)
    if left ~= right then return left < right end
  end
  return #first < #second
end

function Canonical.encode(value)
  local pieces, ancestors, bytes, count = {}, {}, 0, 0
  local string_cache, number_cache = {}, {}
  local function append(piece, path)
    bytes = bytes + #piece
    if bytes > MAX_BYTES then
      return failure("canonical-size-limit", path, "Canonical value exceeds 8 MiB.")
    end
    pieces[#pieces + 1] = piece
    return true
  end

  local encode
  encode = function(item, path, depth)
    count = count + 1
    if depth > MAX_DEPTH or count > MAX_VALUES then
      return failure("canonical-structure-limit", path, "Canonical nesting/value limit exceeded.")
    end
    local kind = type(item)
    if kind == "nil" then return append("z;", path) end
    if kind == "boolean" then return append(item and "b1;" or "b0;", path) end
    if kind == "number" then
      if item ~= item or item == math.huge or item == -math.huge then
        return failure("non-finite-number", path, "Canonical numbers must be finite.")
      end
      local encoded = number_cache[item]
      if not encoded then encoded = number_text(item); number_cache[item] = encoded end
      return append(encoded, path)
    end
    if kind == "string" then
      local encoded = string_cache[item]
      if not encoded then
        if not valid_utf8(item) then
          return failure("invalid-utf8", path, "Canonical strings must contain valid UTF-8.")
        end
        encoded = "s" .. #item .. ":" .. item
        string_cache[item] = encoded
      end
      return append(encoded, path)
    end
    if kind ~= "table" then
      return failure("unsupported-value-type", path, "Canonical values cannot contain " .. kind .. ".")
    end
    if getmetatable(item) ~= nil then
      return failure("table-has-metatable", path, "Canonical tables cannot have metatables.")
    end
    if ancestors[item] then return failure("cyclic-table", path, "Canonical tables cannot contain cycles.") end
    local keys, key_kind, maximum, length = {}, nil, 0, 0
    for key in pairs(item) do
      local current_kind = type(key)
      if current_kind ~= "string" and (current_kind ~= "number" or key < 1 or key % 1 ~= 0) then
        return failure("unsupported-table-key", path, "Object keys must be strings; array keys positive integers.")
      end
      if key_kind and current_kind ~= key_kind then
        return failure("mixed-table-keys", path, "Objects and arrays cannot mix key types.")
      end
      key_kind = current_kind
      length = length + 1
      if current_kind == "string" then keys[#keys + 1] = key
      elseif key > maximum then maximum = key end
    end
    if length == 0 then return append("e;", path) end
    if key_kind == "number" then
      if maximum ~= length then
        return failure("sparse-array", path, "Array keys must be contiguous from one.")
      end
    else
      table.sort(keys, ordered_key)
    end
    local ok, err = append((key_kind == "number" and "a" or "o") .. length .. ":", path)
    if not ok then return nil, err end
    ancestors[item] = true
    for index = 1, length do
      local key = key_kind == "number" and index or keys[index]
      local child_path = path .. "[" .. tostring(key) .. "]"
      if key_kind == "string" then
        ok, err = encode(key, child_path, depth + 1)
        if not ok then return nil, err end
      end
      ok, err = encode(item[key], child_path, depth + 1)
      if not ok then return nil, err end
    end
    ancestors[item] = nil
    return true
  end

  local ok, err = encode(value, "$", 0)
  if not ok then return nil, err end
  return table.concat(pieces)
end

function Canonical.hash(value)
  local encoded, err = Canonical.encode(value)
  if not encoded then return nil, err end
  local first, second = 1, 0
  -- 5552 bytes is the conventional Adler32 reduction block bound; both sums
  -- remain exact integers even on Lua's binary64-only numeric implementation.
  for block = 1, #encoded, 5552 do
    for index = block, math.min(block + 5551, #encoded) do
      first = first + encoded:byte(index)
      second = second + first
    end
    first, second = first % 65521, second % 65521
  end
  return Canonical.version .. ":" .. string.format("%08x", second * 65536 + first) .. ":" .. #encoded
end

return Canonical
