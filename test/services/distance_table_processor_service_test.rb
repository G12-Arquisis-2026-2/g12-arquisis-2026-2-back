require "test_helper"

class DistanceTableProcessorServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "creates and updates destinations from a distance table payload" do
    DistanceTableProcessorService.call(payload("HGW" => {
      "distance" => 62_763_183,
      "transportCost" => 0.0034,
      "enabled" => true
    }))

    assert_equal 1, DistanceTable.count
    destination = DistanceTable.find_by!(destination_code: "HGW")
    assert_equal 62_763_183, destination.distance
    assert_equal BigDecimal("0.0034"), destination.transport_cost
    assert destination.enabled

    DistanceTableProcessorService.call(payload("HGW" => {
      "distance" => 100,
      "transportCost" => 2.5,
      "enabled" => false
    }))

    assert_equal 1, DistanceTable.count
    destination.reload
    assert_equal 100, destination.distance
    assert_equal BigDecimal("2.5"), destination.transport_cost
    assert_not destination.enabled
  end

  test "returns zero when there are no destinations to process" do
    assert_equal 0, DistanceTableProcessorService.call(payload({}))
  end

  test "ignores a repeated idpk and logs it as duplicate" do
    route = { "distance" => 100, "transportCost" => 2.5, "enabled" => true }
    assert_equal 1, DistanceTableProcessorService.call(payload({ "HGW" => route }, "same-idpk"))

    changed = route.merge("distance" => 999)
    assert_equal false, DistanceTableProcessorService.call(payload({ "HGW" => changed }, "same-idpk"))

    assert_equal 100, DistanceTable.find_by!(destination_code: "HGW").distance
    assert_equal 1, AuditLog.where(idpk: "same-idpk", event_type: "DUPLICATE").count
  end

  private

  def payload(distances, idpk = SecureRandom.uuid)
    { "type" => "distance-table", "idpk" => idpk, "data" => { "distances" => distances } }
  end
end