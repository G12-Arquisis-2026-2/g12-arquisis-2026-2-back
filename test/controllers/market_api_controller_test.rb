require "test_helper"

class MarketApiControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @cycle = Cycle.create!(
      cycle_id: "cycle-market-api",
      generation_capacity: 100,
      consumption: 80,
      valid_until: 1.hour.from_now,
      imbalance_price: 2
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
  end

  test "returns live market data for the current cycle" do
    get "/market/live"

    assert_response :success
    assert_equal @cycle.cycle_id, response.parsed_body["cycleId"]
    assert_equal "offer-market-api", response.parsed_body.dig("offers", 0, "offer_id")
  end

  test "returns span experiment data array" do
    get "/experiments/span"

    assert_response :success
    experiment = response.parsed_body.find { |item| item["cycleId"] == @cycle.cycle_id }
    assert_equal 0, experiment["deficitCovered"]
    assert_equal 0.0, experiment["effectiveCost"]
    assert_equal 2.0, experiment["baseline"]
  end
end
