require "test_helper"
require "support/contract_examples"

class TradeRecordProcessorServiceTest < ActiveSupport::TestCase
  include ContractExamples
  self.fixture_table_names = []

  test "saves the official trade-recorded example with every schema field" do
    payload = contract_example("trade-recorded", "route-disabled")

    assert TradeRecordProcessorService.call(payload)

    trade = TradeRecord.sole
    assert_equal payload["idpk"], trade.idpk
    assert_equal payload["msgId"], trade.msg_id
    assert_equal "cycle-9431", trade.cycle_id
    assert_equal %w[swp-91 TAR-9431 TAR COR], [trade.swap_id, trade.offer_id, trade.seller, trade.buyer]
    assert_equal 2000, trade.quantity
    assert_equal BigDecimal("330"), trade.price_per_energy
    assert_equal BigDecimal("660000"), trade.energy_total
    assert_equal BigDecimal("3206.42"), trade.transport_per_energy
    assert_equal BigDecimal("6412840"), trade.transport_total
    assert_equal false, trade.route_enabled
    assert_equal Time.utc(2026, 10, 20, 14, 11, 2), trade.recorded_at
    assert_equal payload, trade.raw_payload
  end

  test "a repeated idpk is not saved twice and is logged as duplicate" do
    payload = contract_example("trade-recorded", "route-enabled")

    assert TradeRecordProcessorService.call(payload)
    assert_not TradeRecordProcessorService.call(payload.merge("msgId" => SecureRandom.uuid))

    assert_equal 1, TradeRecord.count
    assert_equal payload["idpk"], AuditLog.find_by!(event_type: "DUPLICATE").idpk
  end
end
