require "test_helper"

class MarketMessageProcessorTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  include ActiveJob::TestHelper

  test "stores and updates public offers idempotently" do
    offer = build_event("offer", { "cityId" => "HGW", "cycleId" => "cycle-market",
                                   "data" => { "offerId" => "HGW-market", "quantity" => 100, "pricePerEnergy" => 220 } })

    assert MarketMessageProcessor.call(offer)
    assert_not MarketMessageProcessor.call(offer)
    assert_equal 1, MarketOffer.count
    assert_equal 100, MarketOffer.first.remaining

    update = build_event("offer-updated", { "cityId" => "HGW", "cycleId" => "cycle-market",
                                            "data" => { "offerId" => "HGW-market", "remaining" => 45, "pricePerEnergy" => 215 } })
    assert MarketMessageProcessor.call(update)
    assert_equal 45, MarketOffer.first.remaining
    assert_equal 215.to_d, MarketOffer.first.price_per_energy
  end

  test "an echoed local offer update preserves energy reserved in open swaps" do
    previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    offer = MarketOffer.create!(
      cycle_id: "cycle-market",
      offer_id: "TK3-market",
      city_id: "TK3",
      quantity: 100,
      remaining: 100,
      reserved_quantity: 30,
      price_per_energy: 220,
      active: true
    )

    update = build_event("offer-updated", {
      "cityId" => "TK3",
      "cycleId" => "cycle-market",
      "data" => { "offerId" => "TK3-market", "remaining" => 70, "pricePerEnergy" => 215 }
    })
    MarketMessageProcessor.call(update)

    assert_equal 100, offer.reload.remaining
    assert_equal 30, offer.reserved_quantity
    assert_equal 70, offer.remaining - offer.reserved_quantity
  ensure
    ENV["CITY_ID"] = previous_city
  end

  test "records incoming bids once and schedules seller processing" do
    bid = build_event(
      "bid",
      { "cityId" => "COR", "cycleId" => "cycle-market",
        "data" => { "offerId" => "TK3-market", "quantity" => 50 } }
    )

    assert_enqueued_with(job: SellMarketBidJob, args: [bid["idpk"]]) do
      assert MarketMessageProcessor.call(bid)
    end
    assert_not MarketMessageProcessor.call(bid)
    assert_equal 1, MarketBid.where(bid_idpk: bid["idpk"]).count
  end

  test "withdrawn offers stop participating in the book" do
    MarketOffer.create!(
      cycle_id: "cycle-market",
      offer_id: "HGW-market",
      city_id: "HGW",
      quantity: 100,
      remaining: 50,
      price_per_energy: 220,
      active: true
    )

    MarketMessageProcessor.call(
      build_event("offer-withdrawn", { "cityId" => "HGW", "cycleId" => "cycle-market",
                                       "data" => { "offerId" => "HGW-market" } })
    )

    assert_not MarketOffer.first.active?
    assert_equal 0, MarketOffer.first.remaining
  end

  # --- anomalía 1: bid repetido ---

  test "a new bid is processed as before and resends nothing" do
    calls = with_resend_bid_reply(->(payload) { payload }) do
      assert_equal true, MarketMessageProcessor.call(incoming_bid)
    end

    assert_empty calls
    assert_equal 1, MarketBid.count
    assert_equal 0, OutboxMessage.count
  end

  test "a repeated bid with a reply already saved enqueues a copy for the new msgId" do
    with_city("TK3") do
      bid = incoming_bid
      MarketMessageProcessor.call(bid)
      original = OutboxMessage.find_by!(msg_id: accept(bid))
      repeated = bid.merge("msgId" => SecureRandom.uuid)

      assert_equal false, MarketMessageProcessor.call(repeated)

      copy = OutboxMessage.where.not(id: original.id).sole
      assert_equal original.idpk, copy.idpk
      assert_not_equal original.msg_id, copy.msg_id
      assert_equal repeated["msgId"], copy.payload["data"]["target"]
      assert_equal "bid-accepted", copy.message_type
    end
  end

  test "a repeated bid without a reply yet enqueues nothing" do
    bid = incoming_bid
    MarketMessageProcessor.call(bid)

    assert_no_difference -> { OutboxMessage.count } do
      assert_equal false, MarketMessageProcessor.call(bid.merge("msgId" => SecureRandom.uuid))
    end
  end

  test "a repeated offer does not call resend_bid_reply" do
    offer = build_event("offer", { "cityId" => "HGW", "cycleId" => "cycle-market",
                                   "data" => { "offerId" => "HGW-market", "quantity" => 100, "pricePerEnergy" => 220 } })
    MarketMessageProcessor.call(offer)

    calls = with_resend_bid_reply(->(payload) { payload }) do
      assert_equal false, MarketMessageProcessor.call(offer)
    end

    assert_empty calls
  end

  test "if resend_bid_reply raises, call returns the same and the error is only logged" do
    bid = incoming_bid
    MarketMessageProcessor.call(bid)
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    calls = with_resend_bid_reply(->(_payload) { raise ActiveRecord::ConnectionNotEstablished, "db down" }) do
      assert_nothing_raised do
        assert_equal false, MarketMessageProcessor.call(bid.merge("msgId" => SecureRandom.uuid))
      end
    end

    assert_equal 1, calls.size
    assert_includes log.string, "No se pudo reenviar la respuesta al bid #{bid['idpk']}"
  ensure
    Rails.logger = previous_logger
  end

  private

  def incoming_bid
    build_event("bid", { "cityId" => "COR", "cycleId" => "cycle-market",
                         "data" => { "offerId" => "TK3-market", "quantity" => 50 } })
  end

  def accept(bid)
    RabbitMQPublisher.publish(
      { type: "bid-accepted", cycleId: bid["cycleId"],
        data: { target: bid["msgId"], offerId: "TK3-market", quantity: 50, pricePerEnergy: 0.2, amount: 10.0,
                swapId: "swap-1", swapToken: "token", expiresAt: "2026-11-06T15:00:00Z" } },
      to_city: bid["cityId"]
    )
  end

  def with_city(code)
    previous = ENV["CITY_ID"]
    ENV["CITY_ID"] = code
    yield
  ensure
    ENV["CITY_ID"] = previous
  end

  # reemplaza RabbitMQPublisher.resend_bid_reply mientras corre el bloque; devuelve los payloads recibidos
  def with_resend_bid_reply(behavior)
    calls = []
    original = RabbitMQPublisher.method(:resend_bid_reply)
    RabbitMQPublisher.define_singleton_method(:resend_bid_reply) do |payload|
      calls << payload
      behavior.call(payload)
    end
    yield
    calls
  ensure
    RabbitMQPublisher.define_singleton_method(:resend_bid_reply, original)
  end

  def build_event(type, attributes)
    attributes = attributes.deep_stringify_keys
    {
      "idpk" => SecureRandom.uuid,
      "msgId" => SecureRandom.uuid,
      "type" => type,
      "cityId" => attributes["cityId"],
      "cycleId" => attributes["cycleId"],
      "data" => attributes["data"]
    }.compact
  end
end
