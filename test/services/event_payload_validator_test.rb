require "test_helper"

class EventPayloadValidatorTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "accepts numbers and numeric strings" do
    [100, -4, 100.5, "100", "100.5", "-40", "1e3"].each do |value|
      assert_nothing_raised { validate(transfer("quantity" => value)) }
    end
  end

  test "rejects values that are not numbers" do
    ["abc", "", nil, true, false, [1], { "n" => 1 }, "1,5", " 10", "10 ", "NaN", "Infinity"].each do |value|
      assert_raises(EventPayloadValidator::MalformedMessage, "quantity=#{value.inspect}") do
        validate(transfer("quantity" => value))
      end
    end
  end

  test "give and take require numeric energy and pricePerEnergy" do
    %w[give take].each do |type|
      valid = { "target" => "p1", "energy" => 300, "pricePerEnergy" => "1.5" }
      assert_nothing_raised { validate(ledger(type, valid)) }

      error = assert_raises(EventPayloadValidator::MalformedMessage) { validate(ledger(type, valid.merge("energy" => "x"))) }
      assert_equal "data.energy must be a number", error.message
      error = assert_raises(EventPayloadValidator::MalformedMessage) do
        validate(ledger(type, valid.merge("pricePerEnergy" => [1])))
      end
      assert_equal "data.pricePerEnergy must be a number", error.message
    end
  end

  test "demand statement accepts the three formats the ledger reads" do
    [
      { "balance" => { "quantity" => -40, "valuePerKwh" => 200 } },
      { "quantity" => 10, "valuePerKwh" => 2.5 },
      { "balance" => 4, "valuePerKwh" => "3" }
    ].each do |data|
      assert_nothing_raised { validate(ledger("demand-statement", data)) }
    end
  end

  test "demand statement rejects non numeric or missing values" do
    {
      { "balance" => { "quantity" => "abc", "valuePerKwh" => 200 } } => "data.balance.quantity must be a number",
      { "balance" => { "quantity" => 1 } } => "missing field data.balance.valuePerKwh",
      { "quantity" => 10, "valuePerKwh" => true } => "data.valuePerKwh must be a number",
      { "balance" => "x", "valuePerKwh" => 3 } => "data.balance must be a number",
      { "valuePerKwh" => 3 } => "missing field data.quantity"
    }.each do |data, message|
      error = assert_raises(EventPayloadValidator::MalformedMessage, data.inspect) { validate(ledger("demand-statement", data)) }
      assert_equal message, error.message
    end
  end

  private

  def validate(payload)
    EventPayloadValidator.validate!(payload)
  end

  def transfer(data)
    ledger("transfer", data)
  end

  def ledger(type, data)
    { "type" => type, "idpk" => "idpk-1", "cycleId" => "c1", "data" => data }
  end
end
