require "test_helper"

class EventsControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "saves and updates a cycle from a status statement" do
    payload = {
      "type" => "status-statement",
      "cycleId" => "cycle-status-1",
      "data" => {
        "energy" => {
          "generationCapacity" => 1200,
          "consumption" => 950,
          "generationCost" => 0.42
        }
      }
    }

    2.times do
      post "/events", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
    end

    assert_equal 1, Cycle.where(cycle_id: "cycle-status-1").count
    cycle = Cycle.find_by!(cycle_id: "cycle-status-1")
    assert_equal 1200, cycle.generation_capacity
    assert_equal 950, cycle.consumption
    assert_equal BigDecimal("0.42"), cycle.generation_cost
  end
end