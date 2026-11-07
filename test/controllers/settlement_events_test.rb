require "test_helper"
require "support/contract_examples"

# POST /events entrega trade-recorded e imbalance-settlement a sus procesadores nuevos
class SettlementEventsTest < ActionDispatch::IntegrationTest
  include ContractExamples
  self.fixture_table_names = []

  test "trade-recorded is saved once per idpk" do
    payload = contract_example("trade-recorded", "route-enabled")

    post_event payload
    assert_response :created
    post_event payload.merge("msgId" => SecureRandom.uuid)
    assert_equal "duplicate", response.parsed_body["status"]

    assert_equal 1, TradeRecord.where(cycle_id: "cycle-9431").count
  end

  test "imbalance-settlement is saved by cycle and still audited" do
    post_event contract_example("imbalance-settlement", "coverage-negative")

    assert_response :created
    assert_equal(-4700, ImbalanceSettlement.find_by!(cycle_id: "cycle-9431").coverage)
    assert AuditLog.exists?(event_type: "IMBALANCE_SETTLEMENT")
  end

  private

  def post_event(payload)
    post "/events", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end
end
