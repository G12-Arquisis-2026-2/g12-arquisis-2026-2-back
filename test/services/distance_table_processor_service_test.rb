require "test_helper"

class DistanceTableProcessorServiceTest < ActiveSupport::TestCase
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

  private

  def payload(distances)
    { "type" => "distance-table", "data" => { "distances" => distances } }
  end
end