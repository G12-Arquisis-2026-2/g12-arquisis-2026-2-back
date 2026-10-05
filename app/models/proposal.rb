class Proposal < ApplicationRecord
  validates :idpk, presence: true, uniqueness: true
  validates :cycle_id, :direction, :quantity, :generation_cost, :status, presence: true

  # Estados definidos en ADR3
  enum :status, {
    pending: 'PENDING',
    confirmed: 'CONFIRMED',
    paid: 'PAID',
    timeout: 'TIMEOUT'
  }, default: 'PENDING'
end