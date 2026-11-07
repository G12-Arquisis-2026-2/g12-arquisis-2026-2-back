require "test_helper"
require "fileutils"

# Contract test de lo que EMITIMOS por el outbox (bid, bid-accepted, bid-rejected y los del mercado).
# Cada mensaje se deja en el outbox con RabbitMQPublisher.publish, como lo hacen los jobs, y se lee
# de vuelta desde la base: ese payload es el que el connector publica tal cual.
# Si EMITTED_MESSAGES_DIR está definida, escribe cada uno como <type>--<routing key>--<caso>.json y
# connector/contract-tests/validate-contracts.mjs los valida con el validador oficial del curso.
# Sin la variable no escribe nada (así corre igual dentro de bin/rails test).
# Los datos imitan lo que pasan los jobs: kWh enteros y precios BigDecimal.
class EmittedOutboxMessagesTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  CITY = "TK3".freeze
  BUYER = "COR".freeze
  CYCLE = "cycle-9431".freeze
  BID_MSG_ID = "01256c1d-3a8d-4146-8a61-14b1270af094".freeze
  OUT_DIR = ENV.fetch("EMITTED_MESSAGES_DIR", "").strip

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = CITY
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "bid a otra ciudad" do
    message = emit(
      { type: "bid", cycleId: CYCLE, data: { offerId: "COR-9431", quantity: 7300 } },
      "bid", to_city: BUYER
    )

    assert_equal "city.#{BUYER}", @routing_key
    assert_equal 7300, message.dig("data", "quantity")
  end

  test "bid-accepted al comprador" do
    emit(
      {
        type: "bid-accepted",
        cycleId: CYCLE,
        data: {
          target: BID_MSG_ID,
          offerId: "TK3-9431",
          quantity: 7300,
          pricePerEnergy: BigDecimal("51.84"),
          amount: BigDecimal("378432.0"),
          swapId: "swp_7Kq2xV9mPz",
          swapToken: "eyJhbGciOiJFUzI1NiIsImtpZCI6ImsxIn0.eyJzdWIiOiJzd3BfN0txMnhWOW1QeiJ9.c2lnbmF0dXJh",
          expiresAt: Time.utc(2026, 10, 20, 14, 7, 5).iso8601
        }
      },
      "bid-accepted", to_city: BUYER
    )

    assert_equal "city.#{BUYER}", @routing_key
  end

  test "bid-rejected QUANTITY_UNAVAILABLE lleva available" do
    message = emit(bid_rejected("QUANTITY_UNAVAILABLE", available: 1200), "quantity-unavailable", to_city: BUYER)

    assert_equal [ "QUANTITY_UNAVAILABLE", 409 ], [ message["reason"], message["code"] ]
    assert_equal 1200, message.dig("data", "available")
  end

  test "bid-rejected OFFER_WITHDRAWN" do
    message = emit(bid_rejected("OFFER_WITHDRAWN"), "offer-withdrawn", to_city: BUYER)

    assert_equal [ "OFFER_WITHDRAWN", 410 ], [ message["reason"], message["code"] ]
  end

  test "offer al mercado" do
    emit(
      { type: "offer", cycleId: CYCLE, data: { offerId: "TK3-9431", quantity: 12_712, pricePerEnergy: BigDecimal("51.84") } },
      "offer", to_market: true
    )

    assert_equal [ "market", "market.offer.#{CITY}" ], [ @exchange, @routing_key ]
  end

  test "offer-updated al mercado" do
    emit(
      { type: "offer-updated", cycleId: CYCLE, data: { offerId: "TK3-9431", remaining: 5412, pricePerEnergy: BigDecimal("51.84") } },
      "offer-updated", to_market: true
    )

    assert_equal [ "market", "market.offer.#{CITY}" ], [ @exchange, @routing_key ]
  end

  test "offer-withdrawn al mercado" do
    emit({ type: "offer-withdrawn", cycleId: CYCLE, data: { offerId: "TK3-9431" } }, "offer-withdrawn", to_market: true)

    assert_equal [ "market", "market.offer.#{CITY}" ], [ @exchange, @routing_key ]
  end

  private

  # la misma forma que SellMarketBidJob#publish_rejection
  def bid_rejected(reason, available: nil)
    data = { target: BID_MSG_ID, offerId: "TK3-9431", requested: 7300 }
    data[:available] = available if available
    { type: "bid-rejected", cycleId: CYCLE, reason: reason, code: SellMarketBidJob::REJECTION_CODES.fetch(reason), data: data }
  end

  # publica en el outbox, lo lee de la base y lo escribe en OUT_DIR. devuelve el payload guardado
  def emit(payload, label, **destination)
    msg_id = RabbitMQPublisher.publish(payload, **destination)
    record = OutboxMessage.find_by!(msg_id: msg_id)
    # exchange/routing key nil = los del connector (RABBITMQ_EXCHANGE y CENTRAL_ROUTING_KEY)
    @exchange = record.exchange || "energy.x"
    @routing_key = record.routing_key || "central"
    message = record.payload

    assert_equal CITY, message["cityId"]
    assert_equal payload[:type], message["type"]
    assert_not_equal message["msgId"], message["idpk"]
    write(message, label)
    message
  end

  def write(message, label)
    return if OUT_DIR.empty?

    FileUtils.mkdir_p(OUT_DIR)
    File.write(File.join(OUT_DIR, "#{message['type']}--#{@routing_key}--#{label}.json"), "#{JSON.pretty_generate(message)}\n")
  end
end
