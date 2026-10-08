require "test_helper"

class LedgerProcessorServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

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

  test "a give takes out energy and leaves the budget to its payment transfer" do
    transaction = LedgerProcessorService.call(
      "idpk" => "give-1", "cycleId" => "cycle-1", "type" => "give",
      "data" => { "target" => "p1", "energy" => 2024, "pricePerEnergy" => 220.5 }
    )

    assert_equal(-2024, transaction.energy_change)
    assert_equal 0, transaction.budget_change
  end

  test "a take adds energy and charges energy times pricePerEnergy" do
    transaction = LedgerProcessorService.call(
      "idpk" => "take-1", "msgId" => "take-msg-1", "cycleId" => "cycle-1", "type" => "take",
      "data" => { "target" => "p1", "energy" => 2024, "pricePerEnergy" => 210 }
    )

    assert_equal 2024, transaction.energy_change
    assert_equal(-425_040, transaction.budget_change)

    # un solo transfer de pago, con becauseOf = msgId del take
    payment = OutboxMessage.where(message_type: "transfer").sole.payload
    assert_equal "take-msg-1", payment.dig("data", "becauseOf")
    assert_equal 425_040, payment.dig("data", "quantity")
  end

  test "a new message is not logged as a duplicate" do
    %w[transfer demand-statement give take].each do |type|
      LedgerProcessorService.call(
        "idpk" => "new-#{type}", "msgId" => "msg-#{type}", "cycleId" => "cycle-1", "type" => type,
        "data" => { "target" => "p1", "quantity" => 10, "valuePerKwh" => 2.5, "energy" => 10, "pricePerEnergy" => 2 }
      )
    end

    assert_equal 4, Transaction.count
    assert_equal 0, AuditLog.where(event_type: "DUPLICATE").count
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