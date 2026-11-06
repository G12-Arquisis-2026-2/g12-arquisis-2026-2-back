class MarketOffer < ApplicationRecord
  validates :cycle_id, :offer_id, :city_id, presence: true
  validates :quantity, :remaining, :reserved_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :price_per_energy, numericality: { greater_than_or_equal_to: 0 }

  scope :available, -> { where(active: true).where("remaining > reserved_quantity") }

  def local?
    city_id == ENV.fetch("CITY_ID", "TK3")
  end
end
