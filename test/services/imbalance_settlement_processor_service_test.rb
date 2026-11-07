require "test_helper"
require "support/contract_examples"

class ImbalanceSettlementProcessorServiceTest < ActiveSupport::TestCase
  include ContractExamples
  self.fixture_table_names = []

  test "saves the official imbalance-settlement example and keeps it in AuditLog" do
    payload = contract_example("imbalance-settlement", "coverage-negative")

    assert ImbalanceSettlementProcessorService.call(payload)

    settlement = ImbalanceSettlement.sole
    assert_equal payload["idpk"], settlement.idpk
    assert_equal payload["msgId"], settlement.msg_id
    assert_equal "cycle-9431", settlement.cycle_id
    assert_equal "5c9e2a7d-3b1f-4e68-a4d0-8f6b1c3e9a27", settlement.settlement_id
    assert_equal [7300, 12_000, -4700], [settlement.kwh_held, settlement.deficit, settlement.coverage]
    assert_equal BigDecimal("735"), settlement.price_per_energy
    assert_equal BigDecimal("-3454500"), settlement.total
    assert_equal BigDecimal("394450.25"), settlement.balance_after
    assert_equal Time.utc(2026, 10, 20, 14, 15, 3), settlement.settled_at
    assert_equal payload, settlement.raw_payload

    audit = AuditLog.find_by!(event_type: "IMBALANCE_SETTLEMENT")
    assert_equal payload["idpk"], audit.idpk
    assert_equal payload, audit.raw_payload
  end

  test "a repeated idpk is not saved twice and is logged as duplicate" do
    payload = contract_example("imbalance-settlement", "coverage-positive")

    assert ImbalanceSettlementProcessorService.call(payload)
    assert_not ImbalanceSettlementProcessorService.call(payload.merge("msgId" => SecureRandom.uuid))

    assert_equal 1, ImbalanceSettlement.count
    assert_equal 1, AuditLog.where(event_type: "IMBALANCE_SETTLEMENT").count
    assert_equal payload["idpk"], AuditLog.find_by!(event_type: "DUPLICATE").idpk
  end
end
