class Cycle < ApplicationRecord
  validates :cycle_id, presence: true, uniqueness: true
  has_many :transactions, primary_key: :cycle_id, foreign_key: :cycle_id
end