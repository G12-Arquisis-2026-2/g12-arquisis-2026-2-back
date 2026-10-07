require "test_helper"

class RabbitMQPublisherTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "12"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "saves the full envelope as pending and returns the msgId" do
    msg_id = RabbitMQPublisher.publish(type: "negotiation-report", cycleId: "cycle-7",
                                       data: { budgetBalance: 10, energyBalance: -3 })

    record = OutboxMessage.find_by!(msg_id: msg_id)
    message = record.payload

    assert_equal "pending", record.status
    assert_equal 0, record.attempts
    assert_nil record.sent_at
    assert_equal "negotiation-report", record.message_type
    assert_match UUID, message["msgId"]
    assert_match UUID, message["idpk"]
    assert_not_equal message["msgId"], message["idpk"]
    assert_equal "12", message["cityId"]
    assert_equal "cycle-7", message["cycleId"]
    assert_equal({ "budgetBalance" => 10, "energyBalance" => -3 }, message["data"])
    assert Time.iso8601(message["timestamp"]).utc?
    assert message["timestamp"].end_with?("Z")
  end

  test "accepts the payloads the existing services build" do
    payload = CycleService.build_negotiation_report(cycle_id: "cycle-8", budget_balance: 1, energy_balance: 2)

    msg_id = RabbitMQPublisher.publish(payload)

    assert_equal payload[:msgId], msg_id
    assert_equal payload[:idpk], OutboxMessage.find_by!(msg_id: msg_id).idpk
  end

  test "always uses CITY_ID even if the payload brings another cityId" do
    msg_id = RabbitMQPublisher.publish(type: "request", cityId: "OTRA", data: { ask: "status-statement" })

    assert_equal "12", OutboxMessage.find_by!(msg_id: msg_id).payload["cityId"]
  end

  test "a retry reuses the idpk and gets a new msgId" do
    first = RabbitMQPublisher.publish(type: "negotiation-proposal", cycleId: "cycle-7", data: {})
    idpk = OutboxMessage.find_by!(msg_id: first).idpk

    second = RabbitMQPublisher.publish({ type: "negotiation-proposal", cycleId: "cycle-7", data: {} }, idpk: idpk)

    assert_not_equal first, second
    assert_equal idpk, OutboxMessage.find_by!(msg_id: second).idpk
  end

  test "omits cycleId when the message has none" do
    msg_id = RabbitMQPublisher.publish(type: "request", data: { ask: "status-statement" })

    assert_not OutboxMessage.find_by!(msg_id: msg_id).payload.key?("cycleId")
  end

  test "rejects a message whose msgId equals its idpk" do
    same = SecureRandom.uuid

    assert_raises(ArgumentError) { RabbitMQPublisher.publish(type: "request", msgId: same, idpk: same) }
    assert_equal 0, OutboxMessage.count
  end

  test "stores decimal balances as numbers, not as text" do
    msg_id = RabbitMQPublisher.publish(type: "negotiation-report", cycleId: "cycle-7",
                                       data: { budgetBalance: BigDecimal("12.5"), energyBalance: BigDecimal("0") })

    assert_equal({ "budgetBalance" => 12.5, "energyBalance" => 0.0 }, OutboxMessage.find_by!(msg_id: msg_id).payload["data"])
  end
end
