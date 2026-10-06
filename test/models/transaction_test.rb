require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  test "returns summed energy and budget changes for a cycle" do
    create_transaction("cycle-1", 12, -30)
    create_transaction("cycle-1", -2, 5)
    create_transaction("cycle-2", 100, 200)

    assert_equal({ energy: 10, budget: -25 }, Transaction.current_balance_for("cycle-1"))
  end

  test "returns zero balances when the cycle has no transactions" do
    assert_equal({ energy: 0, budget: 0 }, Transaction.current_balance_for("empty-cycle"))
  end

  private

  def create_transaction(cycle_id, energy_change, budget_change)
    Transaction.create!(
      idpk: SecureRandom.uuid,
      cycle_id: cycle_id,
      operation_type: "test",
      energy_change: energy_change,
      budget_change: budget_change,
      raw_data: {}
    )
  end
end