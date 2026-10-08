require "test_helper"

class EventsControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

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
    assert_equal({ "error" => "MALFORMED_MESSAGE", "detail" => "data.quantity must be a number" }, response.parsed_body)
    assert_equal 0, Transaction.count
  end

  test "numeric quantities as integer, decimal or numeric string are saved" do
    [[100, "100"], [100.5, "100.5"], ["100.5", "100.5"]].each_with_index do |(quantity, expected), i|
      post_event transfer_payload("idpk-transfer-ok-#{i}", quantity)

      assert_response :created
      assert_equal BigDecimal(expected), Transaction.find_by!(idpk: "idpk-transfer-ok-#{i}").budget_change
    end
  end

  test "invalid quantities respond 422 and save nothing" do
    ["abc", "", nil, true, [1], { "n" => 1 }, "1,5", " 10"].each_with_index do |quantity, i|
      post_event transfer_payload("idpk-transfer-bad-#{i}", quantity)

      assert_response :unprocessable_content, "quantity=#{quantity.inspect}"
      assert_equal "MALFORMED_MESSAGE", response.parsed_body["error"]
    end
    assert_equal 0, Transaction.count
  end

  test "give with a non numeric pricePerEnergy responds 422" do
    payload = give_take_payload("give", "idpk-give")
    payload["data"]["pricePerEnergy"] = "barato"

    post_event payload

    assert_response :unprocessable_content
    assert_equal "data.pricePerEnergy must be a number", response.parsed_body["detail"]
    assert_equal 0, Transaction.count
  end

  test "demand statement with a non numeric balance responds 422" do
    post_event({ "type" => "demand-statement", "idpk" => "idpk-demand-1", "cycleId" => "c1",
                 "data" => { "balance" => { "quantity" => "mucho", "valuePerKwh" => 215 } } })

    assert_response :unprocessable_content
    assert_equal "data.balance.quantity must be a number", response.parsed_body["detail"]
    assert_equal 0, Transaction.count
  end

  test "demand statement with a numeric balance is saved" do
    post_event({ "type" => "demand-statement", "idpk" => "idpk-demand-1", "cycleId" => "c1",
                 "data" => { "balance" => { "quantity" => 100, "valuePerKwh" => "215.5" } } })

    assert_response :created
    assert_equal BigDecimal("100"), Transaction.find_by!(idpk: "idpk-demand-1").energy_change
  end

  test "types outside the protocol respond 422 unknown type without saving" do
    ["something-else", "negotiation-proposal", nil].each do |type|
      post_event({ "type" => type, "idpk" => "idpk-#{type}", "cycleId" => "c1", "data" => {} })

      assert_response :unprocessable_content
      assert_equal "UNKNOWN_TYPE", response.parsed_body["error"]
    end
    assert_equal 0, AuditLog.count
  end

  test "give and take are saved in the ledger" do
    post_event give_take_payload("give", "idpk-give")
    assert_response :created
    post_event give_take_payload("take", "idpk-take")
    assert_response :created

    give = Transaction.find_by!(idpk: "idpk-give")
    assert_equal [-300, 0], [give.energy_change, give.budget_change] # el cobro llega como transfer
    take = Transaction.find_by!(idpk: "idpk-take")
    assert_equal [300, -450], [take.energy_change, take.budget_change] # 300 * 1.5
    assert_equal "proposal-msg-1", take.raw_data.dig("data", "target")
    assert_equal 0, AuditLog.where(event_type: %w[GIVE TAKE DUPLICATE]).count
    assert_equal 1, OutboxMessage.where(message_type: "transfer").count # solo el pago del take
  end

  test "a repeated give idpk is a duplicate and moves the ledger once" do
    post_event give_take_payload("give", "idpk-give")
    post_event give_take_payload("give", "idpk-give")

    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]
    assert_equal 1, Transaction.where(idpk: "idpk-give").count
    assert_equal 1, AuditLog.where(idpk: "idpk-give", event_type: "DUPLICATE").count
  end

  test "give without data.target responds 422" do
    payload = give_take_payload("give", "idpk-give")
    payload["data"].delete("target")

    post_event payload

    assert_response :unprocessable_content
    assert_equal({ "error" => "MALFORMED_MESSAGE", "detail" => "missing field data.target" }, response.parsed_body)
    assert_equal 0, AuditLog.count
  end

  test "replies from the central are logged without requiring data" do
    post_event({ "type" => "nack", "idpk" => "idpk-nack", "reason" => "MALFORMED_MESSAGE", "code" => 422 })

    assert_response :created
    log = AuditLog.find_by!(idpk: "idpk-nack")
    assert_equal "CENTRAL_NACK", log.event_type
    assert_equal "MALFORMED_MESSAGE", log.reason
  end

  test "an invalid reply from the central reported as central is logged as CENTRAL_<type>" do
    raw = { "msgId" => "m1", "idpk" => "idpk-bad-nack", "type" => "nack", "timestamp" => "ayer" }

    post "/events/rejected", params: { kind: "central", raw: raw, reason: "timestamp debe ser una fecha ISO 8601" }.to_json,
                             headers: json_headers

    assert_response :created
    log = AuditLog.find_by!(idpk: "idpk-bad-nack")
    assert_equal "CENTRAL_NACK", log.event_type
    assert_equal "timestamp debe ser una fecha ISO 8601", log.reason
    assert_equal raw, log.raw_payload
  end

  test "max retries exceeded is logged as discarded, not as a NACK sent" do
    raw = { "msgId" => "m1", "idpk" => "idpk-poison", "type" => "transfer" }

    post "/events/rejected", params: { kind: "discard", raw: raw, reason: "MAX_RETRIES_EXCEEDED" }.to_json,
                             headers: json_headers

    assert_response :created
    assert_equal 1, AuditLog.where(event_type: "DISCARDED", reason: "MAX_RETRIES_EXCEEDED").count
    assert_equal 0, AuditLog.where(event_type: "NACK").count
  end

  test "transfer happy path still saves" do
    post_event transfer_payload("idpk-transfer-1", 10)

    assert_response :created
    assert_equal "saved", response.parsed_body["status"]
    assert_equal BigDecimal("10"), Transaction.find_by!(idpk: "idpk-transfer-1").budget_change
    assert_equal 0, AuditLog.where(event_type: "DUPLICATE").count
  end

  [
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::ConnectionTimeoutError,
    ActiveRecord::ExclusiveConnectionTimeoutError,
    ActiveRecord::DatabaseConnectionError,
    ActiveRecord::ConnectionFailed,
    PG::ConnectionBad,
    PG::UnableToSend
  ].each do |error_class|
    test "a #{error_class} responds 503 service unavailable" do
      with_failing_processor(error_class, "db down") do
        post_event status_payload("idpk-status-1", "cycle-status-1")
      end

      assert_response :service_unavailable
      assert_equal({ "error" => "service_unavailable" }, response.parsed_body)
      assert_equal 0, AuditLog.where(event_type: "NACK").count
    end
  end

  test "a database connection error logs class and message without backtrace" do
    logged = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    with_failing_processor(PG::ConnectionBad, "could not connect to server") do
      post_event status_payload("idpk-status-1", "cycle-status-1")
    end

    assert_response :service_unavailable
    assert_includes logged.string, "PG::ConnectionBad"
    assert_includes logged.string, "could not connect to server"
    assert_not_includes logged.string, "events_controller_test.rb"
  ensure
    Rails.logger = original_logger
  end

  # Errores de SQL que no son de conexión siguen siendo 500: el connector los reintenta con tope
  [ActiveRecord::StatementInvalid, ActiveRecord::NotNullViolation, ActiveRecord::StatementTimeout].each do |error_class|
    test "a #{error_class} responds 500, not 503" do
      with_failing_processor(error_class, "bad sql") do
        post_event status_payload("idpk-status-1", "cycle-status-1")
      end

      assert_response :internal_server_error
      assert_equal({ "error" => "internal_error" }, response.parsed_body)
    end
  end

  [KeyError, NoMethodError, ArgumentError].each do |error_class|
    test "a #{error_class} in a processor responds 500 without internal details" do
      with_failing_processor(error_class, "secreto interno") do
        post_event status_payload("idpk-status-1", "cycle-status-1")
      end

      assert_response :internal_server_error
      assert_equal({ "error" => "internal_error" }, response.parsed_body)
      assert_not_includes response.body, "secreto interno"
      assert_equal 0, AuditLog.where(event_type: "NACK").count
    end
  end

  test "an internal error logs the class, message and backtrace" do
    logged = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    with_failing_processor(KeyError, "key not found: \"x\"") do
      post_event status_payload("idpk-status-1", "cycle-status-1")
    end

    assert_response :internal_server_error
    assert_includes logged.string, "KeyError"
    assert_includes logged.string, "key not found"
    assert_includes logged.string, "events_controller_test.rb"
  ensure
    Rails.logger = original_logger
  end

  test "a race on the idpk (RecordNotUnique) responds 200 duplicate" do
    with_failing_processor(ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint") do
      post_event status_payload("idpk-status-1", "cycle-status-1")
    end

    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]
    assert_nil response.parsed_body["error"]
  end

  private

  # Reemplaza StatusStatementProcessorService.call por uno que lanza error_class mientras corre el bloque
  def with_failing_processor(error_class, message)
    original = StatusStatementProcessorService.method(:call)
    StatusStatementProcessorService.define_singleton_method(:call) { |_payload| raise error_class, message }
    yield
  ensure
    StatusStatementProcessorService.define_singleton_method(:call, original)
  end

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

  def give_take_payload(type, idpk)
    {
      "type" => type,
      "idpk" => idpk,
      "msgId" => "msg-#{idpk}",
      "cycleId" => "c1",
      "data" => { "target" => "proposal-msg-1", "energy" => 300, "pricePerEnergy" => 1.5 }
    }
  end

  def transfer_payload(idpk, quantity)
    { "type" => "transfer", "idpk" => idpk, "cycleId" => "c1", "data" => { "quantity" => quantity } }
  end
end
