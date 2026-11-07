require "test_helper"

class NegotiationStrategyServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @cycle = Cycle.create!(
      cycle_id: "market-cycle",
      generation_capacity: 1_000,
      consumption: 800,
      generation_cost: 200,
      sellable: 200,
      buyback_price: 210,
      imbalance_price: 600,
      min_bid: 10,
      last_offer_at: 1.minute.from_now,
      last_bid_at: 2.minutes.from_now,
      closes_at: 3.minutes.from_now,
      valid_until: 15.minutes.from_now
    )
    @strategy = MarketStrategy.create!(
      sell_price_multiplier: 1.1,
      max_buy_effective_price_ratio: 1,
      span_seconds: 60,
      active: false
    )
  end

  test "pins the active strategy to the cycle once" do
    active = MarketStrategy.create!(sell_price_multiplier: 1.2, max_buy_effective_price_ratio: 0.9,
                                    span_seconds: 30, active: true)

    assert_equal active, NegotiationStrategyService.for_cycle(@cycle)

    replacement = MarketStrategy.activate!(sell_price_multiplier: 1.3, max_buy_effective_price_ratio: 0.8,
                                           span_seconds: 45)
    assert_equal active, NegotiationStrategyService.for_cycle(@cycle)
    assert_equal replacement, MarketStrategy.current
  end

  test "offers above buyback price but never above imbalance price" do
    offer = NegotiationStrategyService.build_offer(cycle: @cycle, offer_id: "TK3-cycle", quantity: 200,
                                                   strategy: @strategy)

    assert_equal "offer", offer[:type]
    assert_equal({ offerId: "TK3-cycle", quantity: 200, pricePerEnergy: 231.to_d }, offer[:data])
  end

  test "floors quantities because KWH is an integer asset" do
    offer = NegotiationStrategyService.build_offer(cycle: @cycle, offer_id: "TK3-cycle", quantity: 200.9,
                                                   strategy: @strategy)

    assert_equal 200, offer.dig(:data, :quantity)
  end

  test "does not post after lastOfferAt or when buyback exceeds imbalance" do
    assert_nil NegotiationStrategyService.build_offer(
      cycle: @cycle, offer_id: "TK3-cycle", quantity: 200, strategy: @strategy,
      now: @cycle.last_offer_at
    )

    @cycle.update!(buyback_price: 601)
    assert_nil NegotiationStrategyService.build_offer(
      cycle: @cycle, offer_id: "TK3-cycle", quantity: 200, strategy: @strategy
    )
  end

  test "chooses the cheapest effective offer using distance times transport cost" do
    offers = [
      { cityId: "AAA", offerId: "aaa", remaining: 100, pricePerEnergy: 220 },
      { cityId: "BBB", offerId: "bbb", remaining: 100, pricePerEnergy: 215 }
    ]
    distances = {
      "AAA" => { distance: 2_000, transportCost: 2, enabled: true },
      "BBB" => { distance: 10_000, transportCost: 0.5, enabled: true }
    }

    bid = NegotiationStrategyService.best_buy_bid(
      cycle: @cycle, offers: offers, distances: distances, energy_needed: 50, strategy: @strategy
    )

    assert_equal "BBB", bid[:city_id]
    assert_equal 50, bid[:quantity]
    assert_equal 220.to_d, bid[:effective_price_per_energy]
    assert_equal({ type: "bid", cycleId: "market-cycle", data: { offerId: "bbb", quantity: 50 } },
                 bid[:payload])
  end

  test "uses the punitive transport rate for a disabled route" do
    offer = { cityId: "AAA", offerId: "aaa", remaining: 100, pricePerEnergy: 220 }
    route = { distance: 2_000, transportCost: 1, disabledRouteTransportCost: 3, enabled: false }

    bid = NegotiationStrategyService.best_buy_bid(
      cycle: @cycle, offers: [offer], distances: { "AAA" => route }, energy_needed: 50, strategy: @strategy
    )

    assert_equal 226.to_d, bid[:effective_price_per_energy]
  end

  test "skips a disabled route missing its transport cost and still considers other routes" do
    offers = [
      { cityId: "AAA", offerId: "aaa", remaining: 100, pricePerEnergy: 200 },
      { cityId: "BBB", offerId: "bbb", remaining: 100, pricePerEnergy: 220 }
    ]
    distances = {
      "AAA" => { distance: 2, transportCost: 1, enabled: false },
      "BBB" => { distance: 1, transportCost: 1, enabled: true }
    }

    bid = NegotiationStrategyService.best_buy_bid(
      cycle: @cycle, offers: offers, distances: distances, energy_needed: 50, strategy: @strategy
    )

    assert_equal "BBB", bid[:city_id]
  end

  test "does not bid on offers below minBid or above the price limit" do
    offers = [
      { cityId: "AAA", offerId: "small", remaining: 9, pricePerEnergy: 1 },
      { cityId: "BBB", offerId: "expensive", remaining: 100, pricePerEnergy: 601 }
    ]
    distances = {
      "AAA" => { distance: 1, transportCost: 1, enabled: true },
      "BBB" => { distance: 1, transportCost: 1, enabled: true }
    }

    assert_nil NegotiationStrategyService.best_buy_bid(
      cycle: @cycle, offers: offers, distances: distances, energy_needed: 50, strategy: @strategy
    )
  end

  test "does not make buyer decisions after lastBidAt" do
    bid = NegotiationStrategyService.best_buy_bid(
      cycle: @cycle,
      offers: [{ cityId: "AAA", offerId: "aaa", remaining: 100, pricePerEnergy: 200 }],
      distances: { "AAA" => { distance: 1, transportCost: 1, enabled: true } },
      energy_needed: 50,
      strategy: @strategy,
      now: @cycle.last_bid_at
    )

    assert_nil bid
  end

  test "rejects bids that are too small or exceed available offer quantity" do
    bid = { "cityId" => "AAA", "data" => { "offerId" => "offer-1", "quantity" => 5 } }
    assert_equal "BID_TOO_SMALL", NegotiationStrategyService.bid_rejection_reason(
      cycle: @cycle, offer_id: "offer-1", bid: bid, remaining: 100
    )

    bid["data"]["quantity"] = 20
    assert_equal "QUANTITY_UNAVAILABLE", NegotiationStrategyService.bid_rejection_reason(
      cycle: @cycle, offer_id: "offer-1", bid: bid, remaining: 10
    )
  end
end
