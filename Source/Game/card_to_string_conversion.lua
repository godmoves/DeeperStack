--- Converts between string and numeric representations of cards.
-- @module card_to_string_conversion

require 'string'
require 'torch'
local arguments = require 'Settings.arguments'
local game_settings =  require 'Settings.game_settings'

local M = {}

--- All possible card suits
M.suit_table = {'c', 'd', 'h', 's'}

--- All possible card ranks
M.rank_table = {'2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A'}

--- Gets the suit of a card.
-- @param card the numeric representation of the card
-- @return the index of the suit
function M:card_to_suit(card)
  --TODO check if this should be (card - 1)
  return (card - 1) % game_settings.suit_count + 1
end

--- Gets the rank of a card.
-- @param card the numeric representation of the card
-- @return the index of the rank
function M:card_to_rank(card)
  return torch.floor((card - 1) / game_settings.suit_count ) + 1
end

--- Holds the string representation for every possible card, indexed by its
-- numeric representation.
M.card_to_string_table ={}
for card = 1, game_settings.card_count do
  local rank_name = M.rank_table[M:card_to_rank(card)]
  local suit_name = M.suit_table[M:card_to_suit(card)]
  M.card_to_string_table[card] = rank_name .. suit_name
end

--- Holds the numeric representation for every possible card, indexed by its
-- string representation.
M.string_to_card_table = {}
for card = 1, game_settings.card_count do
  M.string_to_card_table[M.card_to_string_table[card]] = card
end

--- Converts a card's numeric representation to its string representation.
-- @param card the numeric representation of a card
-- @return the string representation of the card
function M:card_to_string(card)
  assert(card > 0 and card <= game_settings.card_count )
  return M.card_to_string_table[card]
end

--- Converts several cards' numeric representations to their string
-- representations.
-- @param cards a vector of numeric representations of cards
-- @return a string containing each card's string representation, concatenated
function M:cards_to_string(cards)
  if cards:dim() == 0 then
    return ""
  end

  local out = ""
  for card =1, cards:size(1) do
    out = out .. self:card_to_string(cards[card])
  end
  return out
end

--- Converts a card's string representation to its numeric representation.
-- @param card_string the string representation of a card
-- @return the numeric representation of the card
function M:string_to_card(card_string)
  local card = M.string_to_card_table[card_string]
  assert(card > 0 and card <= game_settings.card_count)
  return card
end

--- Converts a string representing zero or more board cards to a
-- vector of numeric representations.
-- @param card_string either the empty string or a string representation of a
-- card
-- @return either an empty tensor or a tensor containing the numeric
-- representation of the card
function M:string_to_board(card_string)
  assert(card_string)
  
  if card_string == '' then
    return arguments.Tensor{}
  end

  local num_cards = string.len(card_string) / 2
  board = arguments.Tensor(num_cards)
  for i = 1, num_cards do
    board[i] = self:string_to_card(string.sub(card_string, i * 2 - 1, i * 2))
  end
  return board
end

return M
