require "test_helper"

class EventsControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "saves a cycle from a status statement" do
    post_event status_payload("idpk-status-1", "cycle-status-1")

    assert_response :created
    assert_equal "saved", response.parsed_body["status"]
    cycle = Cycle.find_by!(cycle_id: "cycle-status-1")
    assert_equal 1200, cycle.generation_capacity
    assert_equal 950, cycle.consumption
    assert_equal BigDecimal("0.42"), cycle.generation_cost
    assert_equal Time.iso8601("2026-10-07T12:30:00Z"), cycle.valid_until
  end

  test "a new idpk for the same cycle updates it" do
    post_event status_payload("idpk-status-1", "cycle-status-1")
    post_event status_payload("idpk-status-2", "cycle-status-1", generation_capacity: 5)

    assert_response :created
    assert_equal 1, Cycle.where(cycle_id: "cycle-status-1").count
    assert_equal 5, Cycle.find_by!(cycle_id: "cycle-status-1").generation_capacity
  end

  test "a repeated status statement idpk does not modify the cycle" do
    post_event status_payload("idpk-status-1", "cycle-status-1")
    cycle = Cycle.find_by!(cycle_id: "cycle-status-1")

    post_event status_payload("idpk-status-1", "cycle-status-1", generation_capacity: 5)

    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]
    assert_equal cycle.attributes, cycle.reload.attributes
    assert_equal 1, AuditLog.where(idpk: "idpk-status-1", event_type: "DUPLICATE").count
  end

  test "a repeated distance table idpk does not modify the destinations" do
    post_event distance_payload("idpk-distance-1", "distance" => 100, "transportCost" => 0.5, "enabled" => true)
    destination = DistanceTable.find_by!(destination_code: "HGW")

    post_event distance_payload("idpk-distance-1", "distance" => 999, "transportCost" => 9.9, "enabled" => false)

    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]
    assert_equal destination.attributes, destination.reload.attributes
    assert_equal 1, DistanceTable.count
    assert_equal 1, AuditLog.where(idpk: "idpk-distance-1", event_type: "DUPLICATE").count
  end

  test "invalid JSON responds 422 malformed message" do
    post "/events", params: '{"type": "transfer", "data": ', headers: json_headers

    assert_response :unprocessable_content
    assert_equal "MALFORMED_MESSAGE", response.parsed_body["error"]
    assert response.parsed_body["detail"].present?
  end

  test "status statement without validUntil responds 422 and saves nothing" do
    payload = status_payload("idpk-status-1", "cycle-status-1")
    payload["data"].delete("validUntil")

    post_event payload

    assert_response :unprocessable_content
    assert_equal({ "error" => "MALFORMED_MESSAGE", "detail" => "missing field data.validUntil" }, response.parsed_body)
    assert_not Cycle.exists?(cycle_id: "cycle-status-1")
    assert_not ProcessedMessage.exists?(idpk: "idpk-status-1")
  end

  test "distance table with a route missing a field responds 422" do
    post_event distance_payload("idpk-distance-1", "distance" => 100, "enabled" => true)

    assert_response :unprocessable_content
    assert_equal "MALFORMED_MESSAGE", response.parsed_body["error"]
    assert_equal 0, DistanceTable.count
  end

  test "transfer with a non numeric quantity responds 422" do
    post_event transfer_payload("idpk-transfer-1", "abc")

    assert_response :unprocessable_content
    assert_equal "MALFORMED_MESSAGE", response.parsed_body["error"]
    assert_equal 0, Transaction.count
  end

  test "unknown types respond 422 without saving" do
    %w[give take something-else].each do |type|
      post_event({ "type" => type, "idpk" => "idpk-#{type}", "cycleId" => "c1", "data" => {} })

      assert_response :unprocessable_content
      assert_equal "UNKNOWN_TYPE", response.parsed_body["error"]
    end
    assert_equal 0, AuditLog.count
  end

  test "transfer happy path still saves" do
    post_event transfer_payload("idpk-transfer-1", 10)

    assert_response :created
    assert_equal "saved", response.parsed_body["status"]
    assert_equal BigDecimal("10"), Transaction.find_by!(idpk: "idpk-transfer-1").budget_change
  end

  test "unexpected errors respond 500" do
    original = StatusStatementProcessorService.method(:call)
    StatusStatementProcessorService.define_singleton_method(:call) do |_payload|
      raise ActiveRecord::ConnectionNotEstablished, "db down"
    end

    post_event status_payload("idpk-status-1", "cycle-status-1")

    assert_response :internal_server_error
    assert_equal({ "error" => "Internal Server Error" }, response.parsed_body)
  ensure
    StatusStatementProcessorService.define_singleton_method(:call, original)
  end

  private

  def json_headers
    { "CONTENT_TYPE" => "application/json" }
  end

  def post_event(payload)
    post "/events", params: payload.to_json, headers: json_headers
  end

  def status_payload(idpk, cycle_id, generation_capacity: 1200)
    {
      "type" => "status-statement",
      "idpk" => idpk,
      "cycleId" => cycle_id,
      "data" => {
        "validUntil" => "2026-10-07T12:30:00Z",
        "energy" => {
          "generationCapacity" => generation_capacity,
          "consumption" => 950,
          "generationCost" => 0.42
        }
      }
    }
  end

  def distance_payload(idpk, route)
    { "type" => "distance-table", "idpk" => idpk, "data" => { "distances" => { "HGW" => route } } }
  end

  def transfer_payload(idpk, quantity)
    { "type" => "transfer", "idpk" => idpk, "cycleId" => "c1", "data" => { "quantity" => quantity } }
  end
end
