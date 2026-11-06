require "test_helper"

class MarketStrategiesControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "GET returns the active strategy, creating defaults when needed" do
    get "/market-strategy"

    assert_response :success
    assert_equal 1.1, response.parsed_body["sellPriceMultiplier"].to_f
    assert_equal 1.0, response.parsed_body["maxBuyEffectivePriceRatio"].to_f
    assert_equal 60, response.parsed_body["spanSeconds"]
  end

  test "PATCH versions the strategy and retains omitted parameters" do
    original = MarketStrategy.current

    patch "/market-strategy", params: { marketStrategy: { spanSeconds: 30 } }

    assert_response :created
    updated = MarketStrategy.current
    assert_not_equal original.id, updated.id
    assert_equal 30, updated.span_seconds
    assert_equal original.sell_price_multiplier, updated.sell_price_multiplier
    assert_equal original.max_buy_effective_price_ratio, updated.max_buy_effective_price_ratio
  end

  test "invalid strategy settings are rejected without deactivating the current version" do
    original = MarketStrategy.current

    patch "/market-strategy", params: { marketStrategy: { maxBuyEffectivePriceRatio: 1.1 } }

    assert_response :unprocessable_entity
    assert_equal original.id, MarketStrategy.current.id
  end
end
