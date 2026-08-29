local Queue = {}

function Queue.depth(state)
  return #state.queue + (state.active and 1 or 0)
end

function Queue.push(state, command)
  state.queue[#state.queue + 1] = command
end

function Queue.pop(state)
  if #state.queue == 0 then return nil end
  return table.remove(state.queue, 1)
end

function Queue.clear(state)
  state.queue = {}
end

return Queue
