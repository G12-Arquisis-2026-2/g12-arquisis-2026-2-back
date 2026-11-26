require "test_helper"

class OutboxControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "12"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  def publish(type)
    msg_id = publish_outbox(type: type, cycleId: "cycle-7", data: {})
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
    bid = publish_outbox({ type: "bid", cycleId: "cycle-7", data: {} }, to_city: "HGW")
    offer = publish_outbox({ type: "offer", cycleId: "cycle-7", data: {} }, to_market: true)

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
  # --- reserva para el relay (ADR8) ---

  def claim(relay)
    post "/events/outbox/claim", params: { relay: relay }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    response.parsed_body.map { |item| item["id"] }
  end

  test "two claims in a row from two relays never get the same row" do
    rows = 3.times.map { publish("negotiation-report") }

    first = claim("relay-a")
    second = claim("relay-b")

    assert_equal rows.map(&:id), first
    assert_empty second
    assert_equal ["relay-a"], OutboxMessage.distinct.pluck(:locked_by)
  end

  test "the same relay gets its own rows back, renewing the reservation" do
    row = publish("negotiation-report")
    claim("relay-a")

    travel(20.seconds) { assert_equal [row.id], claim("relay-a") }
  end

  test "an expired reservation is available again" do
    row = publish("negotiation-report")
    claim("relay-a")

    travel(29.seconds) { assert_empty claim("relay-b") }
    travel(31.seconds) { assert_equal [row.id], claim("relay-b") }
    assert_equal "relay-b", row.reload.locked_by
  end

  test "messages to the central come first, then the rest in creation order" do
    offer = publish_outbox({ type: "offer", cycleId: "cycle-7", data: {} }, to_market: true)
    report = publish("negotiation-report")
    bid = publish_outbox({ type: "bid", cycleId: "cycle-7", data: {} }, to_city: "HGW")
    request = publish("request")
    ids = OutboxMessage.where(msg_id: [offer, bid]).order(:id).pluck(:id)

    assert_equal [report.id, request.id] + ids, claim("relay-a")
  end

  test "only pending rows are claimed and marking clears the reservation" do
    sent = publish("transfer")
    pending = publish("negotiation-report")
    sent.mark_sent!

    assert_equal [pending.id], claim("relay-a")
    mark(pending, status: "sent")

    pending.reload
    assert_nil pending.locked_by
    assert_nil pending.locked_until
  end

  test "claim needs the relay name" do
    publish("negotiation-report")

    post "/events/outbox/claim", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unprocessable_entity
    assert_nil OutboxMessage.first.locked_by
  end

  # --- atraso del outbox ---

  test "lag answers the three numbers" do
    travel_to(30.seconds.ago) { publish("negotiation-report") }
    publish("request").mark_failed!("prueba")

    get "/events/outbox/lag"

    assert_response :ok
    body = response.parsed_body
    assert_equal %w[outbox_failed_last_hour outbox_oldest_pending_age_seconds outbox_pending_count], body.keys.sort
    assert_in_delta 30, body["outbox_oldest_pending_age_seconds"], 1
    assert_equal 1, body["outbox_pending_count"]
    assert_equal 1, body["outbox_failed_last_hour"]
  end

  # --- oferta vigente para republicar tras una reconexión ---

  def offer_row(type, status: "sent", cycle: "cycle-7")
    msg_id = publish_outbox({ type: type, cycleId: cycle, data: { offerId: "12-#{cycle}" } }, to_market: true)
    OutboxMessage.find_by!(msg_id: msg_id).tap { |row| row.update!(status: status) }
  end

  def open_cycle(**changes)
    Cycle.create!({ cycle_id: "cycle-7", valid_until: 20.minutes.from_now, last_offer_at: 10.minutes.from_now }.merge(changes))
  end

  test "current-offer hands out the last offer sent in the current cycle" do
    open_cycle
    offer_row("offer")
    updated = offer_row("offer-updated")
    offer_row("offer-updated", status: "pending")

    get "/events/outbox/current-offer"

    assert_response :ok
    assert_equal updated.payload, response.parsed_body["payload"]
    assert_equal ["market", "market.offer.12"], response.parsed_body.values_at("exchange", "routing_key")
  end

  test "current-offer has nothing after a withdrawal, after lastOfferAt or for another cycle" do
    open_cycle
    offer_row("offer", cycle: "cycle-6")
    get "/events/outbox/current-offer"
    assert_response :no_content

    offer_row("offer")
    offer_row("offer-withdrawn")
    get "/events/outbox/current-offer"
    assert_response :no_content
  end

  test "current-offer has nothing once the cycle stops taking offers" do
    open_cycle(last_offer_at: 1.minute.ago)
    offer_row("offer")

    get "/events/outbox/current-offer"

    assert_response :no_content
  end
end
