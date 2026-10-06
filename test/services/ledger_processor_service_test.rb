require "test_helper"

class LedgerProcessorServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "processes transfers without changing energy" do
    transaction = LedgerProcessorService.call(
      "idpk" => "transfer-1",
      "cycleId" => "cycle-1",
      "type" => "transfer",
      "data" => { "quantity" => 125 }
    )

    assert_equal "cycle-1", transaction.cycle_id
    assert_equal "transfer", transaction.operation_type
    assert_equal 0, transaction.energy_change
    assert_equal 125, transaction.budget_change
    assert_equal "transfer", transaction.raw_data["type"]
  end

  test "subtracts the demand statement value from the budget for positive quantity" do
    transaction = LedgerProcessorService.call(
      "idpk" => "demand-1",
      "cycleId" => "cycle-1",
      "type" => "demand-statement",
      "data" => { "quantity" => 10, "valuePerKwh" => 2.5 }
    )

    assert_equal 10, transaction.energy_change
    assert_equal(-25, transaction.budget_change)
  end

  test "adds the absolute demand statement value to the budget for negative quantity" do
    transaction = LedgerProcessorService.call(
      "idpk" => "demand-2",
      "cycleId" => "cycle-1",
      "type" => "demand-statement",
      "data" => { "quantity" => -10, "valuePerKwh" => 2.5 }
    )

    assert_equal(-10, transaction.energy_change)
    assert_equal 25, transaction.budget_change
  end

  test "reads demand quantity and price from a nested balance object" do
    transaction = LedgerProcessorService.call(
      "idpk" => "demand-balance-object",
      "cycleId" => "cycle-1",
      "type" => "demand-statement",
      "data" => { "balance" => { "quantity" => -4, "valuePerKwh" => 3 } }
    )

    assert_equal(-4, transaction.energy_change)
    assert_equal 12, transaction.budget_change
  end

  test "reads demand quantity from a scalar balance" do
    transaction = LedgerProcessorService.call(
      "idpk" => "demand-balance-scalar",
      "cycleId" => "cycle-1",
      "type" => "demand-statement",
      "data" => { "balance" => 4, "valuePerKwh" => 3 }
    )

    assert_equal 4, transaction.energy_change
    assert_equal(-12, transaction.budget_change)
  end

  test "logs a retry when the idpk already exists" do
    payload = {
      "idpk" => "transfer-duplicate",
      "cycleId" => "cycle-1",
      "type" => "transfer",
      "data" => { "quantity" => 125 }
    }

    LedgerProcessorService.call(payload)

    assert_equal false, LedgerProcessorService.call(payload)

    audit_log = AuditLog.find_by!(idpk: "transfer-duplicate", event_type: "DUPLICATE")
    assert_match(/retry/i, audit_log.reason)
    assert_equal payload, audit_log.raw_payload
  end

  test "logs a retry when the database rejects a duplicate idpk" do
    payload = {
      "idpk" => "transfer-race",
      "cycleId" => "cycle-1",
      "type" => "transfer",
      "data" => { "quantity" => 125 }
    }

    Transaction.new(
      idpk: payload["idpk"],
      cycle_id: payload["cycleId"],
      operation_type: "transfer",
      energy_change: 0,
      budget_change: 125,
      raw_data: payload
    ).save!(validate: false)

    assert_equal false, LedgerProcessorService.call(payload)

    audit_log = AuditLog.find_by!(idpk: "transfer-race", event_type: "DUPLICATE")
    assert_match(/retry/i, audit_log.reason)
    assert_equal payload, audit_log.raw_payload
  end
end