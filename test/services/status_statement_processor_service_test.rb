require "test_helper"

class StatusStatementProcessorServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "stores E2 market inputs and snapshots the active strategy" do
    opened_at = Time.current.change(usec: 0)
    active = MarketStrategy.create!(
      sell_price_multiplier: 1.15,
      max_buy_effective_price_ratio: 0.95,
      span_seconds: 45,
      active: true
    )
    payload = {
      "type" => "status-statement",
      "idpk" => SecureRandom.uuid,
      "cycleId" => "cycle-with-market",
      "data" => {
        "validUntil" => (opened_at + 15.minutes).iso8601,
        "energy" => {
          "generationCapacity" => 1_000,
          "consumption" => 800,
          "generationCost" => 200,
          "sellable" => 200
        },
        "market" => {
          "buybackPrice" => 210,
          "imbalancePrice" => 600,
          "minBid" => 10,
          "lastOfferAt" => (opened_at + 8.minutes).iso8601,
          "lastBidAt" => (opened_at + 9.minutes).iso8601,
          "closesAt" => (opened_at + 10.minutes).iso8601,
          "reportOpensAt" => (opened_at + 10.minutes).iso8601
        }
      }
    }

    assert StatusStatementProcessorService.call(payload)

    cycle = Cycle.find_by!(cycle_id: "cycle-with-market")
    assert_equal 200, cycle.sellable
    assert_equal 210.to_d, cycle.buyback_price
    assert_equal 600.to_d, cycle.imbalance_price
    assert_equal 10, cycle.min_bid
    assert_equal active, cycle.market_strategy
  end
end
