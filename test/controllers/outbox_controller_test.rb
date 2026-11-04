require "test_helper"

class OutboxControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "12"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  def publish(type)
    msg_id = RabbitMQPublisher.publish(type: type, cycleId: "cycle-7", data: {})
    OutboxMessage.find_by!(msg_id: msg_id)
  end

  def mark(record, body)
    post "/events/outbox/#{record.id}", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  test "lists only pending messages, oldest first" do
    first = publish("negotiation-report")
    sent = publish("transfer")
    last = publish("request")
    sent.mark_sent!

    get "/events/outbox"

    assert_response :ok
    assert_equal [first.id, last.id], response.parsed_body.map { |item| item["id"] }
    assert_equal first.payload, response.parsed_body.first["payload"]
  end

  test "hands out the destination of each message (empty = the central)" do
    central = publish("negotiation-report")
    bid = RabbitMQPublisher.publish({ type: "bid", cycleId: "cycle-7", data: {} }, to_city: "HGW")
    offer = RabbitMQPublisher.publish({ type: "offer", cycleId: "cycle-7", data: {} }, to_market: true)

    get "/events/outbox"

    items = response.parsed_body.index_by { |item| item["payload"]["msgId"] }
    assert_equal [nil, nil], items[central.msg_id].values_at("exchange", "routing_key")
    assert_equal [nil, "city.HGW"], items[bid].values_at("exchange", "routing_key")
    assert_equal ["market", "market.offer.12"], items[offer].values_at("exchange", "routing_key")
    assert_equal %w[exchange id payload routing_key], items[bid].keys.sort
  end

  test "does not hand out a report whose cycle window already closed" do
    Cycle.create!(cycle_id: "cycle-7", valid_until: Time.utc(2026, 10, 7, 14, 20))
    report = travel_to(Time.utc(2026, 10, 7, 14, 16)) { publish("negotiation-report") }
    request = publish("request")

    travel_to(Time.utc(2026, 10, 7, 14, 20)) { get "/events/outbox" }

    assert_equal [request.id], response.parsed_body.map { |item| item["id"] }
    assert_equal "failed", report.reload.status
  end

  test "marks a message as sent" do
    record = publish("negotiation-report")

    mark(record, status: "sent")

    assert_response :ok
    record.reload
    assert_equal "sent", record.status
    assert_equal 1, record.attempts
    assert_not_nil record.sent_at
  end

  test "marks a message as failed with the reason" do
    record = publish("negotiation-report")

    mark(record, status: "failed", reason: "cityId ajeno")

    assert_response :ok
    record.reload
    assert_equal "failed", record.status
    assert_equal "cityId ajeno", record.error
    assert_nil record.sent_at
  end

  test "rejects an unknown status and leaves the message pending" do
    record = publish("negotiation-report")

    mark(record, status: "otro")

    assert_response :unprocessable_entity
    assert_equal "pending", record.reload.status
  end

  test "answers 404 for a message that does not exist" do
    post "/events/outbox/999999", params: { status: "sent" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :not_found
  end
end
