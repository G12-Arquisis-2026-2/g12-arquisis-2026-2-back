class MarketBid < ApplicationRecord
  SIDES = %w[buy sell].freeze
  ACTIVE_STATUSES = %w[pending sent proposing proposed accepting].freeze

  validates :cycle_id, :offer_id, :bid_idpk, :bid_msg_id, :buyer_city, :seller_city, presence: true
  validates :side, inclusion: { in: SIDES }
  validates :status, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def self.unresolved_buy(cycle_id)
    where(cycle_id: cycle_id, side: "buy", status: %w[sent accepting proposed])
  end
end
