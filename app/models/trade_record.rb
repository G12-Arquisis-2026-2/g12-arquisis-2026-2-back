class TradeRecord < ApplicationRecord
  validates :idpk, :msg_id, :cycle_id, :swap_id, :seller, :buyer, presence: true
end
