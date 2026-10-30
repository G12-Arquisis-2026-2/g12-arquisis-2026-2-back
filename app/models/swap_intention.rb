class SwapIntention < ApplicationRecord
  enum :status, {
    pending: 0,
    settled: 1,
    rejected: 2,
    cancelled: 3,
    expired: 4
  }, default: :pending

  validates :idpk, :give_amount, :take_amount, presence: true
end
