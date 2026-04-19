local M = {}

function M.distance(a, b)
  a = a or ""
  b = b or ""
  if a == b then return 0 end
  if #a == 0 then return #b end
  if #b == 0 then return #a end
  if #a < #b then a, b = b, a end
  local la, lb = #a, #b
  local prev = {}
  for j = 0, lb do prev[j] = j end
  local cur = {}
  for i = 1, la do
    cur[0] = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local del = prev[j] + 1
      local ins = cur[j - 1] + 1
      local sub = prev[j - 1] + cost
      local m = del
      if ins < m then m = ins end
      if sub < m then m = sub end
      cur[j] = m
    end
    for j = 0, lb do prev[j] = cur[j] end
  end
  return prev[lb]
end

function M.similarity(a, b)
  a = a or ""
  b = b or ""
  local longest = math.max(#a, #b)
  if longest == 0 then return 1.0 end
  local d = M.distance(a, b)
  return 1.0 - (d / longest)
end

return M
