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

  private

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
