--- Assorted tools.
--@module tools
local M = {C = {}, max_choose = 55}

--- Generates a string representation of a table.
--@param table the table
--@return the string
function M:table_to_string(table)
  local out = ''
  for key,value in pairs(table) do

    local val_string = ''

    if type(value) == 'table' then
      val_string = self:table_to_string(value)
    else
      val_string = tostring(value)
    end

    out = out .. tostring(key) .. ":" .. val_string .. ", "
  end

  return "{" .. out .. "}"
end

--- An arbitrarily large number used for clamping regrets.
--@return the number
function M:max_number()
  return 999999
end

--- Initializes the choose table.
-- @local
function M:_init_choose()
  for i = 0, self.max_choose do
    for j = 0, self.max_choose do
      self.C[i * self.max_choose + j] = 0
    end
  end

  for i = 0, self.max_choose do
    self.C[i * self.max_choose] = 1
    self.C[i * self.max_choose + i] = 1
  end

  for i = 1, self.max_choose do
    for j = 1, i do
      self.C[i * self.max_choose + j] = self.C[(i - 1) * self.max_choose + j - 1] + self.C[(i - 1) * self.max_choose + j]
    end
  end
end

M:_init_choose()

--- Return the number of all possible choices
-- @param n total number to choose from
-- @param k number of item we need to choose
-- @return the number of all possible choices
function M:choose(n, k)
  return self.C[n*self.max_choose + k]
end

--- Get pot size according to game setting and street.
function M:get_pot_size(street, nolimit)
  local min_pot = {}
  local max_pot = {}

  if nolimit then
    min_pot = {100, 200, 400, 2000, 6000}
    max_pot = {100, 400, 2000, 6000, 18000}
  else
    if street == 4 then
      min_pot = {2, 12, 24}
      max_pot = {12, 24, 48}
    elseif street == 3 then
      min_pot = {2, 8, 16}
      max_pot = {8, 16, 24}
    elseif street == 2 then
      min_pot = {2, 4, 6}
      max_pot = {4, 6, 10}
    end
  end

  return min_pot, max_pot
end

--- Get path to save training files
-- @param street current street
-- @param nolimit if we are playing no limit game
-- @return path to save training files
function M:get_trianing_path(street, nolimit)
  local train_folder = "xxx/"
  if nolimit then
    train_folder = "NoLimit/"
  else
    train_folder = "Limit/"
  end

  if street == 4 then
    train_folder = train_folder .. "river_raw/"
  elseif street == 3 then
    train_folder = train_folder .. "turn_raw/"
  elseif street == 2 then
    train_folder = train_folder .. "flop_raw/"
  elseif street == 1 then
    train_folder = train_folder .. "preflop_raw/"
  end

  return train_folder
end

--- Get path to model file
-- @param street current street
-- @param aux if we are using preflow net
-- @param nolimit if we are playing no limit game
-- @return path to model file
function M:get_model_path(street, aux, nolimit)
  local net_file = ""

  if nolimit then
    net_file = net_file .. "NoLimit/"
  else
    net_file = net_file .. "Limit/"
  end

  assert(street <= 3)

  if aux then
    assert(street == 1)
    net_file = net_file .. "preflop-aux/"
  else
    if street == 3 then
      net_file = net_file .. "river/"
    elseif street == 2 then
      net_file = net_file .. "turn/"
    elseif street == 1 then
      net_file = net_file .. "flop/"
    end
  end

  return net_file
end

return M
