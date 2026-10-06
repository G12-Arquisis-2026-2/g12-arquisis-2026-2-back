class Transaction < ApplicationRecord
  belongs_to :cycle, primary_key: :cycle_id, foreign_key: :cycle_id, optional: true

  validates :idpk, presence: true, uniqueness: true
  validates :cycle_id, :operation_type, :energy_change, :budget_change, :raw_data, presence: true

  def self.current_balance_for(cycle_id)
    energy, budget = where(cycle_id: cycle_id).pick(
      Arel.sql("COALESCE(SUM(energy_change), 0)"),
      Arel.sql("COALESCE(SUM(budget_change), 0)")
    )

    { energy: energy, budget: budget }
  end
end