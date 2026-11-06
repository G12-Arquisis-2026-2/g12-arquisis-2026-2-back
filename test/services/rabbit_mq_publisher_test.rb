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

  # --- destino (E2): a otra ciudad o al mercado ---

  test "without a destination it goes to the central, with exchange and routing_key empty" do
    record = OutboxMessage.find_by!(msg_id: RabbitMQPublisher.publish(type: "negotiation-report", data: {}))

    assert_nil record.exchange
    assert_nil record.routing_key
  end

  test "to_city keeps the usual exchange and uses the routing key of that city" do
    msg_id = RabbitMQPublisher.publish({ type: "bid", cycleId: "cycle-7", data: { offerId: "offer-1", quantity: 7300 } },
                                       to_city: "HGW")
    record = OutboxMessage.find_by!(msg_id: msg_id)

    assert_nil record.exchange
    assert_equal "city.HGW", record.routing_key
    assert_equal "bid", record.payload["type"]
    assert_equal "12", record.payload["cityId"]
    assert_equal({ "offerId" => "offer-1", "quantity" => 7300 }, record.payload["data"])
  end

  test "to_city also works with the fields as keywords" do
    msg_id = RabbitMQPublisher.publish(type: "bid-accepted", cycleId: "cycle-7", data: {}, to_city: "MET")

    assert_equal "city.MET", OutboxMessage.find_by!(msg_id: msg_id).routing_key
  end

  test "to_city follows PEER_ROUTING_KEY_FORMAT" do
    previous = ENV["PEER_ROUTING_KEY_FORMAT"]
    ENV["PEER_ROUTING_KEY_FORMAT"] = "peer.%s"
    msg_id = RabbitMQPublisher.publish({ type: "bid", data: {} }, to_city: "HGW")

    assert_equal "peer.HGW", OutboxMessage.find_by!(msg_id: msg_id).routing_key
  ensure
    ENV["PEER_ROUTING_KEY_FORMAT"] = previous
  end

  test "to_market uses the market exchange and only our own offer routing key" do
    msg_id = RabbitMQPublisher.publish({ type: "offer", cycleId: "cycle-7", data: { quantity: 7300 } }, to_market: true)
    record = OutboxMessage.find_by!(msg_id: msg_id)

    assert_equal "market", record.exchange
    assert_equal "market.offer.12", record.routing_key
  end

  test "a message cannot go to a city and to the market at the same time" do
    assert_raises(ArgumentError) { RabbitMQPublisher.publish({ type: "offer", data: {} }, to_city: "HGW", to_market: true) }
    assert_equal 0, OutboxMessage.count
  end

  test "bid-rejected carries reason and code at the top level" do
    msg_id = RabbitMQPublisher.publish(
      { type: "bid-rejected", cycleId: "cycle-7", reason: "QUANTITY_UNAVAILABLE", code: 409,
        data: { target: "msg-bid", offerId: "offer-1", available: 100 } },
      to_city: "HGW"
    )
    payload = OutboxMessage.find_by!(msg_id: msg_id).payload

    assert_equal "QUANTITY_UNAVAILABLE", payload["reason"]
    assert_equal 409, payload["code"]
    assert_equal "msg-bid", payload["data"]["target"]
  end

  test "other types do not copy reason and code" do
    msg_id = RabbitMQPublisher.publish(type: "bid", reason: "x", code: 1, data: {})

    assert_not OutboxMessage.find_by!(msg_id: msg_id).payload.key?("reason")
  end

  # --- anomalía 1: bid repetido ---

  def incoming_bid(changes = {})
    { "msgId" => SecureRandom.uuid, "idpk" => SecureRandom.uuid, "type" => "bid", "cityId" => "HGW",
      "cycleId" => "cycle-7", "data" => { "offerId" => "12-cycle-7", "quantity" => 100 } }.merge(changes)
  end

  def save_bid(bid)
    MarketBid.create!(cycle_id: bid["cycleId"], offer_id: bid.dig("data", "offerId"), bid_idpk: bid["idpk"],
                      bid_msg_id: bid["msgId"], side: "sell", buyer_city: "HGW", seller_city: "12",
                      quantity: 100, status: "pending", raw_payload: bid)
  end

  def accept(bid)
    RabbitMQPublisher.publish(
      { type: "bid-accepted", cycleId: "cycle-7",
        data: { target: bid["msgId"], offerId: "12-cycle-7", quantity: 100, pricePerEnergy: 0.2, amount: 20.0,
                swapId: "swap-1", swapToken: "token", expiresAt: "2026-11-06T15:00:00Z" } },
      to_city: "HGW"
    )
  end

  def reject(bid)
    RabbitMQPublisher.publish(
      { type: "bid-rejected", cycleId: "cycle-7", reason: "QUANTITY_UNAVAILABLE", code: 409,
        data: { target: bid["msgId"], offerId: "12-cycle-7", requested: 100, available: 10 } },
      to_city: "HGW"
    )
  end

  test "a bid reply stores the idpk of the bid it answers" do
    bid = incoming_bid
    save_bid(bid)

    assert_equal bid["idpk"], OutboxMessage.find_by!(msg_id: accept(bid)).reply_to_idpk
    assert_equal bid["idpk"], OutboxMessage.find_by!(msg_id: reject(bid)).reply_to_idpk
  end

  test "other messages, or a reply to an unknown bid, have no reply_to_idpk" do
    other = RabbitMQPublisher.publish({ type: "bid", cycleId: "cycle-7", data: {} }, to_city: "HGW")
    unknown = accept(incoming_bid)

    assert_nil OutboxMessage.find_by!(msg_id: other).reply_to_idpk
    assert_nil OutboxMessage.find_by!(msg_id: unknown).reply_to_idpk
  end

  test "a repeated bid with a reply already sent enqueues a copy with the same idpk and the new target" do
    bid = incoming_bid
    save_bid(bid)
    original = OutboxMessage.find_by!(msg_id: accept(bid))
    original.mark_sent!
    repeated = bid.merge("msgId" => SecureRandom.uuid)

    copy_id = RabbitMQPublisher.resend_bid_reply(repeated)

    copy = OutboxMessage.find_by!(msg_id: copy_id)
    assert_equal "pending", copy.status
    assert_equal original.idpk, copy.idpk
    assert_equal original.idpk, copy.payload["idpk"]
    assert_not_equal original.msg_id, copy.msg_id
    assert_equal copy.msg_id, copy.payload["msgId"]
    assert_equal repeated["msgId"], copy.payload["data"]["target"]
    assert_equal original.payload["data"].except("target"), copy.payload["data"].except("target")
    assert_equal ["bid-accepted", nil, "city.HGW"], [ copy.message_type, copy.exchange, copy.routing_key ]
    assert_equal bid["idpk"], copy.reply_to_idpk
  end

  test "the copy of a bid-rejected keeps reason and code" do
    bid = incoming_bid
    save_bid(bid)
    reject(bid)

    copy = OutboxMessage.find_by!(msg_id: RabbitMQPublisher.resend_bid_reply(bid.merge("msgId" => SecureRandom.uuid)))

    assert_equal ["QUANTITY_UNAVAILABLE", 409], copy.payload.values_at("reason", "code")
    assert_equal 10, copy.payload["data"]["available"]
  end

  test "a repeated bid without a reply yet enqueues nothing" do
    bid = incoming_bid
    save_bid(bid)

    assert_no_difference -> { OutboxMessage.count } do
      assert_nil RabbitMQPublisher.resend_bid_reply(bid.merge("msgId" => SecureRandom.uuid))
    end
  end

  test "a failed reply is not resent" do
    bid = incoming_bid
    save_bid(bid)
    OutboxMessage.find_by!(msg_id: accept(bid)).mark_failed!("ACCESS_REFUSED")

    assert_no_difference -> { OutboxMessage.count } do
      assert_nil RabbitMQPublisher.resend_bid_reply(bid.merge("msgId" => SecureRandom.uuid))
    end
  end

  test "resends the last reply given to that bid" do
    bid = incoming_bid
    save_bid(bid)
    accept(bid)
    reject(bid)

    copy = OutboxMessage.find_by!(msg_id: RabbitMQPublisher.resend_bid_reply(bid.merge("msgId" => SecureRandom.uuid)))

    assert_equal "bid-rejected", copy.message_type
  end

  test "accepts the bid payload with symbol keys" do
    bid = incoming_bid
    save_bid(bid)
    accept(bid)

    assert RabbitMQPublisher.resend_bid_reply(bid.merge("msgId" => SecureRandom.uuid).symbolize_keys)
  end
end
