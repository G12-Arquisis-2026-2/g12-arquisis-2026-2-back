require "test_helper"
require "support/contract_examples"

class CycleSettlementSummaryTest < ActiveSupport::TestCase
  include ContractExamples
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    # en los ejemplos oficiales COR es el comprador
    ENV["CITY_ID"] = "COR"
    @cycle = Cycle.create!(cycle_id: "cycle-9431")
    DistanceTable.create!(destination_code: "HGW", distance: 2_400_000, transport_cost: 0.0306, enabled: true,
                          disabled_route_transport_cost: 0.5)
    DistanceTable.create!(destination_code: "TAR", distance: 1_000_000, transport_cost: 0.01, enabled: false,
                          disabled_route_transport_cost: 3.20642)
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "a cycle with two trades and a settlement returns the exact CycleSummary shape" do
    TradeRecordProcessorService.call(contract_example("trade-recorded", "route-disabled"))
    TradeRecordProcessorService.call(contract_example("trade-recorded", "route-enabled"))
    TradeRecordProcessorService.call(foreign_trade)
    ImbalanceSettlementProcessorService.call(contract_example("imbalance-settlement", "coverage-negative"))

    expected = {
      transportCharges: [
        { counterpartCityId: "HGW", distanceKm: 2400.0, unitCost: 0.0306, totalCost: 536_112.0,
          routeDisabledPenalty: false, appliedAt: "2026-10-20T14:07:31Z" },
        { counterpartCityId: "TAR", distanceKm: 1000.0, unitCost: 3.20642, totalCost: 6_412_840.0,
          routeDisabledPenalty: true, appliedAt: "2026-10-20T14:11:02Z" }
      ],
      imbalanceSettlement: { coverageKwh: -4700, pricePerKwh: 735.0, totalAmount: -3_454_500.0,
                             type: "deficit", settledAt: "2026-10-20T14:15:03Z" }
    }
    assert_equal expected, CycleSettlementSummary.call(@cycle)
  end

  test "amounts are JSON numbers, not strings" do
    TradeRecordProcessorService.call(contract_example("trade-recorded", "route-enabled"))
    ImbalanceSettlementProcessorService.call(contract_example("imbalance-settlement", "coverage-positive"))

    json = JSON.parse(CycleSettlementSummary.call(@cycle).to_json)

    charge = json["transportCharges"].sole
    %w[distanceKm unitCost totalCost].each { |key| assert_kind_of Numeric, charge[key], key }
    settlement = json["imbalanceSettlement"]
    %w[coverageKwh pricePerKwh totalAmount].each { |key| assert_kind_of Numeric, settlement[key], key }
    assert_equal 576_616.32, settlement["totalAmount"]
    assert_equal "surplus", settlement["type"]
  end

  test "a cycle without imbalance-settlement returns null and no charges" do
    assert_equal({ transportCharges: [], imbalanceSettlement: nil }, CycleSettlementSummary.call(@cycle))
  end

  # la central cobra el transporte solo al comprador
  test "a trade where we are the seller is not a transport charge" do
    TradeRecordProcessorService.call(contract_example("trade-recorded", "route-enabled"))
    TradeRecordProcessorService.call(trade_as_seller)

    charges = CycleSettlementSummary.call(@cycle)[:transportCharges]
    assert_equal ["HGW"], charges.map { |charge| charge[:counterpartCityId] }
  end

  test "accepts a cycle_id instead of a Cycle" do
    TradeRecordProcessorService.call(contract_example("trade-recorded", "route-enabled"))

    assert_equal "HGW", CycleSettlementSummary.call("cycle-9431")[:transportCharges].sole[:counterpartCityId]
  end

  test "zero coverage counts as surplus with no money moved" do
    ImbalanceSettlementProcessorService.call(contract_example("imbalance-settlement", "coverage-zero"))

    settlement = CycleSettlementSummary.call(@cycle)[:imbalanceSettlement]
    assert_equal [0, "surplus", 0.0], settlement.values_at(:coverageKwh, :type, :totalAmount)
  end

  private

  # trade entre otras dos ciudades en el mismo ciclo: no es nuestro
  def foreign_trade
    trade_with(seller: "TAR", buyer: "HGW")
  end

  # COR vende a TAR: nos pagan la energía, pero el transporte se le cobra a TAR
  def trade_as_seller
    trade_with(seller: "COR", buyer: "TAR")
  end

  def trade_with(seller:, buyer:)
    example = contract_example("trade-recorded", "route-enabled")
    example.merge("idpk" => SecureRandom.uuid, "msgId" => SecureRandom.uuid,
                  "data" => example["data"].merge("seller" => seller, "buyer" => buyer, "swapId" => SecureRandom.uuid))
  end
end
