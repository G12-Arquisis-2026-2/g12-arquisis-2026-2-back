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
