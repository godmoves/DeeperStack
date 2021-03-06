--- Uses the neural net to estimate value at the end of the first betting round.
-- @classmod next_round_value

require 'torch'
require 'math'
local bucketer = require 'Nn.bucketer'
local card_tools = require 'Game.card_tools'
local arguments = require 'Settings.arguments'
local game_settings = require 'Settings.game_settings'
local constants = require 'Settings.constants'
local tools = require 'tools'

local NextRoundValue = torch.class('NextRoundValue')

--- Constructor.
--
-- Creates a tensor that can translate hand ranges to bucket ranges
-- on any board.
-- @param nn the neural network
-- @param board current board
-- @param nrv next round value
function NextRoundValue:__init(nn, board, nrv)
  self.nn = nn
  if nrv == nil then
    self:_init_bucketing(board)
  else
    self._street = nrv._street
    self.bucket_count = nrv.bucket_count
    self.board_count = nrv.board_count
    self._range_matrix = nrv._range_matrix:clone()
    self._range_matrix_board_view = self._range_matrix:view(game_settings.hand_count, self.board_count, self.bucket_count)
    self._reverse_value_matrix = nrv._reverse_value_matrix:clone()
  end
end

--- Initializes the tensor that translates hand ranges to bucket ranges.
-- @local
function NextRoundValue:_init_bucketing(board)
  local timer = torch.Timer()
  timer:reset()
  local street = card_tools:board_to_street(board)
  self._street = street
  self.bucket_count = bucketer:get_bucket_count(street+1)
  local boards = card_tools:get_next_round_boards(board)

  self.board_count = boards:size(1)
  self._range_matrix = arguments.Tensor(game_settings.hand_count, self.board_count * self.bucket_count ):zero()
  self._range_matrix_board_view = self._range_matrix:view(game_settings.hand_count, self.board_count, self.bucket_count)

  for idx = 1, self.board_count do
    local board = boards[idx]

    local buckets = bucketer:compute_buckets(board)
    local class_ids = torch.range(1, self.bucket_count)

    if arguments.gpu then
      buckets = buckets:cuda()
      class_ids = class_ids:cuda()
    else
      class_ids = class_ids:float()
    end

    class_ids = class_ids:view(1, self.bucket_count):expand(game_settings.hand_count, self.bucket_count)
    local card_buckets = buckets:view(game_settings.hand_count, 1):expand(game_settings.hand_count, self.bucket_count)

    --finding all strength classes
    --matrix for transformation from card ranges to strength class ranges
    self._range_matrix_board_view[{{}, idx, {}}][torch.eq(class_ids, card_buckets)] = 1
  end

  --matrix for transformation from class values to card values
  self._reverse_value_matrix = self._range_matrix:t():clone()
  --we need to div the matrix by the sum of possible boards (from point of view of each hand)
  local num_new_cards = game_settings.board_card_count[street+1] - game_settings.board_card_count[street]
  local num_cur_cards = game_settings.board_card_count[street]

  local den = tools:choose(
    game_settings.card_count - num_cur_cards - 2*game_settings.hand_card_count,
    num_new_cards)
  local weight_constant = 1/den -- count
  self._reverse_value_matrix:mul(weight_constant)
  print("nextround init_bucket time: " .. timer:time().real)
end

--- Converts a range vector over private hands to a range vector over buckets.
-- @param card_range a probability vector over private hands
-- @param bucket_range a vector in which to store the output probabilities
--  over buckets
-- @local
function NextRoundValue:_card_range_to_bucket_range(card_range, bucket_range)
  bucket_range:mm(card_range, self._range_matrix)
end

--- Converts a value vector over buckets to a value vector over private hands.
-- @param bucket_value a value vector over buckets
-- @param card_value a vector in which to store the output values over
-- private hands
-- @local
function NextRoundValue:_bucket_value_to_card_value(bucket_value, card_value)
  card_value:mm(bucket_value, self._reverse_value_matrix)
end

--- Converts a value vector over buckets to a value vector over private hands
-- given a particular set of board cards.
-- TODO: fix this
-- @param board a non-empty vector of board cards
-- @param bucket_value a value vector over buckets
-- @param card_value a vector in which to store the output values over
-- private hands
-- @local
function NextRoundValue:_bucket_value_to_card_value_on_board(board, bucket_value, card_value)
  local board_idx = card_tools:get_board_index(board)
  local board_matrix = self._range_matrix_board_view[{{}, board_idx, {}}]:t()
  local serialized_card_value = card_value:view(-1, game_settings.hand_count)
  local serialized_bucket_value = bucket_value[{{}, {}, board_idx, {}}]:clone():view(-1, self.bucket_count)
  serialized_card_value:mm(serialized_bucket_value, board_matrix)
end

--- Initializes the value calculator with the pot size of each state that
-- we are going to evaluate.
--
-- During continual re-solving, there is one pot size for each initial state
-- of the second betting round (before board cards are dealt).
-- @param pot_sizes a vector of pot sizes betting round ends
-- @param batch_size batch size
function NextRoundValue:start_computation(pot_sizes, batch_size)
  self.iter = 0
  self.pot_sizes = pot_sizes:view(-1, 1):clone()
  self.pot_sizes = self.pot_sizes:expand(self.pot_sizes:size(1),batch_size):clone()
  self.pot_sizes = self.pot_sizes:view(-1, 1)
  self.batch_size = self.pot_sizes:size(1)
end

--- Gives the predicted counterfactual values at each evaluated state, given
-- input ranges.
--
-- @{start_computation} must be called first. Each state to be evaluated must
-- be given in the same order that pot sizes were given for that function.
-- Keeps track of iterations internally, so should be called exactly once for
-- every iteration of continual re-solving.
--
-- @param ranges An Nx2xK tensor, where N is the number of states evaluated
-- (must match input to @{start_computation}), 2 is the number of players, and
-- K is the number of private hands. Contains N sets of 2 range vectors.
-- @param values an Nx2xK tensor in which to store the N sets of 2 value vectors
-- which are output
function NextRoundValue:get_value(ranges, values)
  assert(ranges and values)
  assert(ranges:size(1) == self.batch_size)
  self.iter = self.iter + 1
  if self.iter == 1 then
    --initializing data structures
    self.next_round_inputs = arguments.Tensor(self.batch_size, self.board_count, (self.bucket_count * constants.players_count + 1)):zero()
    self.next_round_values = arguments.Tensor(self.batch_size, self.board_count, constants.players_count,  self.bucket_count ):zero()
    self.transposed_next_round_values = arguments.Tensor(self.batch_size, constants.players_count, self.board_count, self.bucket_count)
    self.next_round_extended_range = arguments.Tensor(self.batch_size, constants.players_count, self.board_count * self.bucket_count ):zero()
    self.next_round_serialized_range = self.next_round_extended_range:view(-1, self.bucket_count)
    self.range_normalization = arguments.Tensor()
    self.value_normalization = arguments.Tensor(self.batch_size, constants.players_count, self.board_count)
    --handling pot feature for the nn
    local den = 0
    assert(self._street <= 3)
    if game_settings.nl then
      den = arguments.stack
    else
      if self._street == 4 then
        den = 48
      elseif self._street == 3 then
        den = 48
      elseif self._street == 2 then
        den = 24
      elseif self._street == 1 then
        den = 10
      else
        den = -1
      end
    end
    local nn_bet_input = self.pot_sizes:clone():mul(1/den)
    nn_bet_input = nn_bet_input:view(-1, 1):expand(self.batch_size, self.board_count)
    self.next_round_inputs[{{}, {}, {-1}}]:copy(nn_bet_input)
  end

  --we need to find if we need remember something in this iteration
  local use_memory = self.iter > arguments.cfr_skip_iters
  if use_memory and self.iter == arguments.cfr_skip_iters + 1 then
    --first iter that we need to remember something - we need to init data structures
    self.range_normalization_memory = arguments.Tensor(self.batch_size * self.board_count * constants.players_count, 1):zero()
    self.counterfactual_value_memory = arguments.Tensor(self.batch_size, constants.players_count, self.board_count, self.bucket_count):zero()
  end

  --computing bucket range in next street for both players at once
  self:_card_range_to_bucket_range(ranges:view(self.batch_size * constants.players_count, -1), self.next_round_extended_range:view(self.batch_size * constants.players_count, -1))
  self.range_normalization:sum(self.next_round_serialized_range, 2)
  local rn_view = self.range_normalization:view(self.batch_size, constants.players_count, self.board_count)
  for player = 1, constants.players_count do
    self.value_normalization[{{}, player, {}}]:copy(rn_view[{{}, 3 - player, {}}])
  end
  if use_memory then
    self.range_normalization_memory:add(self.value_normalization)
  end
  --eliminating division by zero
  self.range_normalization[torch.eq(self.range_normalization, 0)] = 1
  self.next_round_serialized_range:cdiv(self.range_normalization:expandAs(self.next_round_serialized_range))
  local serialized_range_by_player = self.next_round_serialized_range:view(self.batch_size, constants.players_count, self.board_count, self.bucket_count)
  for player = 1, constants.players_count do
    local player_range_index = {(player -1) * self.bucket_count + 1, player * self.bucket_count}
    self.next_round_inputs[{{}, {}, player_range_index}]:copy(self.next_round_extended_range[{{},player, {}}])
  end

  --using nn to compute values
  local serialized_inputs_view= self.next_round_inputs:view(self.batch_size * self.board_count, -1)
  local serialized_values_view= self.next_round_values:view(self.batch_size * self.board_count, -1)

  --computing value in the next round
  self.nn:get_value(serialized_inputs_view, serialized_values_view)

  --normalizing values back according to the orginal range sum
  local normalization_view = self.value_normalization:view(self.batch_size, constants.players_count, self.board_count, 1):transpose(2,3)
  self.next_round_values:cmul(normalization_view:expandAs(self.next_round_values))

  self.transposed_next_round_values:copy(self.next_round_values:transpose(3,2))
  --remembering the values for the next round
  if use_memory then
    self.counterfactual_value_memory:add(self.transposed_next_round_values)
  end
  --translating bucket values back to the card values
  self:_bucket_value_to_card_value(self.transposed_next_round_values:view(self.batch_size * constants.players_count, -1), values:view(self.batch_size * constants.players_count, -1))
end

--- Gives the average counterfactual values on the given board across previous
-- calls to @{get_value}.
--
-- Used to update opponent counterfactual values during re-solving after board
-- cards are dealt.
-- @param board a non-empty vector of board cards
-- @param values a tensor in which to store the values
function NextRoundValue:get_value_on_board(board, values)
  --check if we have evaluated correct number of iterations
  assert(self.iter == arguments.cfr_iters )
  local batch_size = values:size(1)
  assert(batch_size == self.batch_size)

  self:_prepare_next_round_values()

  self:_bucket_value_to_card_value_on_board(board, self.counterfactual_value_memory, values)
end

--- Normalizes the counterfactual values remembered between @{get_value} calls
-- so that they are an average rather than a sum.
-- @local
function NextRoundValue:_prepare_next_round_values()

  assert(self.iter == arguments.cfr_iters )

  --do nothing if already prepared
  if self._values_are_prepared then
    return
  end

  --eliminating division by zero
  self.range_normalization_memory[torch.eq(self.range_normalization_memory, 0)] = 1
  local serialized_memory_view = self.counterfactual_value_memory:view(-1, self.bucket_count)
  serialized_memory_view:cdiv(self.range_normalization_memory:expandAs(serialized_memory_view))

  self._values_are_prepared = true
end
