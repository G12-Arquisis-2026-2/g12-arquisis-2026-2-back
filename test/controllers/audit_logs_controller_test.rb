require "test_helper"

# GET /audit-logs sale de AuditLog (lo que registran POST /events y POST /events/rejected), no de datos fijos
class AuditLogsControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "without logs responds 200 with empty lists" do
    get "/audit-logs"

    assert_response :ok
    assert_equal({ "duplicates" => [], "rejectedMessages" => [] }, response.parsed_body)
  end

  test "a repeated transfer idpk shows up as a duplicate with both msgIds" do
    post_event transfer_payload("idpk-tr-1", "msg-original")
    post_event transfer_payload("idpk-tr-1", "msg-retry")
    assert_equal "duplicate", response.parsed_body["status"]

    get "/audit-logs"

    assert_response :ok
    duplicates = response.parsed_body["duplicates"]
    assert_equal 1, duplicates.size
    duplicate = duplicates.first
    assert_equal "idpk-tr-1", duplicate["idpk"]
    assert_equal "msg-original", duplicate["originalMsgId"]
    assert_equal "msg-retry", duplicate["duplicateMsgId"]
    assert_equal "transfer", duplicate["type"]
    assert_equal "ignored_ledger_unchanged", duplicate["action"]
    assert_equal AuditLog.find_by!(event_type: "DUPLICATE").created_at.iso8601, duplicate["detectedAt"]
    assert_equal [], response.parsed_body["rejectedMessages"]
  end

  test "a repeated distance table idpk shows up as a duplicate" do
    distance = { "type" => "distance-table", "idpk" => "idpk-dt-1", "msgId" => "msg-dt-1",
                 "data" => { "distances" => { "HGW" => { "distance" => 1, "transportCost" => 0.1, "enabled" => true } } } }
    post_event distance
    post_event distance.merge("msgId" => "msg-dt-2")

    get "/audit-logs"

    duplicate = response.parsed_body["duplicates"].sole
    assert_equal "idpk-dt-1", duplicate["idpk"]
    assert_equal "distance-table", duplicate["type"]
    assert_equal "msg-dt-2", duplicate["duplicateMsgId"]
    # distance-table no guarda el msgId del primer mensaje
    assert_nil duplicate["originalMsgId"]
  end

  test "a NACK reported by the connector shows up with its code" do
    message = transfer_payload("idpk-bad", "msg-bad").merge("type" => "transfer")
    report_rejected("nack", message, "MALFORMED_MESSAGE")

    get "/audit-logs"

    rejected = response.parsed_body["rejectedMessages"].sole
    assert_equal "nack", rejected["type"]
    assert_equal "msg-bad", rejected["msgId"]
    assert_equal "MALFORMED_MESSAGE", rejected["reason"]
    assert_equal 422, rejected["code"]
    assert_equal "transfer idpk idpk-bad", rejected["message"]
  end

  test "a message discarded by the connector shows up without msgId" do
    report_rejected("discard", "{no es json", "el cuerpo no es un objeto JSON")

    get "/audit-logs"

    rejected = response.parsed_body["rejectedMessages"].sole
    assert_equal "discarded", rejected["type"]
    assert_nil rejected["msgId"]
    assert_nil rejected["code"]
    assert_equal "el cuerpo no es un objeto JSON", rejected["reason"]
    assert_equal "{no es json", rejected["message"]
  end

  test "an error from the central shows up with the central's reason and code" do
    post_event({ "type" => "error", "idpk" => "idpk-err-1", "msgId" => "msg-err-1", "timestamp" => Time.current.iso8601,
                 "reason" => "CYCLE_UNKNOWN", "code" => 404,
                 "data" => { "target" => "msg-nuestro", "message" => "ciclo desconocido" } })
    assert_response :created

    get "/audit-logs"

    rejected = response.parsed_body["rejectedMessages"].sole
    assert_equal "error", rejected["type"]
    assert_equal "msg-err-1", rejected["msgId"]
    assert_equal "CYCLE_UNKNOWN", rejected["reason"]
    assert_equal 404, rejected["code"]
    assert_equal "ciclo desconocido", rejected["message"]
  end

  test "lists newest first" do
    report_rejected("discard", "primero", "a")
    travel 1.minute do
      report_rejected("discard", "segundo", "b")
    end

    get "/audit-logs"

    assert_equal %w[segundo primero], response.parsed_body["rejectedMessages"].map { |log| log["message"] }
  end

  private

  def post_event(payload)
    post "/events", params: payload.to_json, headers: json_headers
  end

  def report_rejected(kind, raw, reason)
    post "/events/rejected", params: { kind: kind, raw: raw, reason: reason }.to_json, headers: json_headers
    assert_response :created
  end

  def json_headers
    { "CONTENT_TYPE" => "application/json" }
  end

  def transfer_payload(idpk, msg_id)
    { "type" => "transfer", "idpk" => idpk, "msgId" => msg_id, "cycleId" => "c1", "data" => { "quantity" => 10 } }
  end
end
