class MarketStrategy < ApplicationRecord
  validates :sell_price_multiplier, numericality: { greater_than_or_equal_to: 1 }
  validates :max_buy_effective_price_ratio, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :span_seconds, numericality: { only_integer: true, greater_than: 0 }

  scope :active, -> { where(active: true) }

  def self.current
    active.first_or_create!
  rescue ActiveRecord::RecordNotUnique
    active.first!
  end

  def self.activate!(attributes)
    transaction do
      active.update_all(active: false, updated_at: Time.current)
      create!(attributes.merge(active: true))
    end
  end
end
