require "test_helper"

class MarketApiControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @cycle = Cycle.create!(
      cycle_id: "cycle-market-api",
      generation_capacity: 100,
      consumption: 120,
      valid_until: 1.hour.from_now,
      imbalance_price: 2,
      sellable: 30,
      buyback_price: 0.5
    )
    MarketOffer.create!(
      cycle_id: @cycle.cycle_id,
      offer_id: "offer-market-api",
      city_id: "HGW",
      quantity: 50,
      remaining: 50,
      reserved_quantity: 0,
      price_per_energy: 1.5,
      active: true
    )
    DistanceTable.create!(
      destination_code: "HGW",
      distance: 1_200,
      transport_cost: 0.4,
      disabled_route_transport_cost: 2,
      enabled: true
    )
  end

  test "returns live market data for the current cycle" do
    get "/market/live"

    assert_response :success
    response_body = response.parsed_body
    assert_equal "TK3", response_body["cityId"]
    assert response_body["updatedAt"].present?
    offer = response_body.fetch("offers").first
    assert_equal "offer-market-api", offer["offerId"]
    assert_equal "HGW", offer["cityId"]
    assert_equal 1.2, offer["distanceKm"]
    assert_equal 0.4, offer["transportCostPerKwh"]
    assert_equal 1.98, offer["effectivePrice"]
    assert_equal true, offer["routeEnabled"]
    assert_nil offer["offer_id"]
  end

  test "returns current cycle bids as swaps in camelCase" do
    bid = market_bid(cycle_id: @cycle.cycle_id)
    market_bid(cycle_id: "older-cycle")

    get "/market/swaps"

    assert_response :success
    response_body = response.parsed_body
    assert_equal @cycle.cycle_id, response_body["cycleId"]
    swap = response_body.fetch("swaps").sole
    assert_equal bid.bid_idpk, swap["bidIdpk"]
    assert_equal "offer-market-api", swap["offerId"]
    assert_equal 12.5, swap["pricePerEnergy"]
    assert_equal "swap-market-api", swap["swapId"]
    assert_nil swap["bid_idpk"]
  end

  test "returns span experiment data array" do
    get "/experiments/span"

    assert_response :success
    experiment = response.parsed_body.find { |item| item["cycleId"] == @cycle.cycle_id }
    assert_equal 0, experiment["deficitCovered"]
    assert_equal 0.0, experiment["effectiveCost"]
    assert_equal 25.0, experiment["baseline"]
  end

  private

  def market_bid(cycle_id:)
    MarketBid.create!(
      cycle_id: cycle_id,
      offer_id: "offer-market-api",
      bid_idpk: SecureRandom.uuid,
      bid_msg_id: SecureRandom.uuid,
      side: "buy",
      buyer_city: "TK3",
      seller_city: "HGW",
      quantity: 10,
      price_per_energy: 12.5,
      amount: 125,
      status: "settled",
      swap_id: "swap-market-api"
    )
  end
end
