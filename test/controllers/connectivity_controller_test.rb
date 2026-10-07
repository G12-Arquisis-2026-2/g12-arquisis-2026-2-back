require "test_helper"

# GET /connectivity sale de las distance-table guardadas (POST /events), no de datos fijos
class ConnectivityControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "without a distance table responds 200 with no destinations" do
    get "/connectivity"

    assert_response :ok
    body = response.parsed_body
    assert_equal "TK3", body["cityId"]
    assert_equal({}, body["distances"])
    assert_nil body["updatedAt"]
  end

  test "shows exactly the destinations of the received distance table" do
    post_event distance_payload("idpk-dt-1",
                                "HGW" => { "distance" => 1500, "transportCost" => 0.25, "enabled" => true },
                                "TAR" => { "distance" => 3200, "transportCost" => 0.5, "enabled" => false })
    assert_response :created

    get "/connectivity"

    assert_response :ok
    body = response.parsed_body
    assert_equal "TK3", body["cityId"]
    assert_equal({ "HGW" => { "distance" => 1500, "transportCost" => 0.25, "enabled" => true },
                   "TAR" => { "distance" => 3200, "transportCost" => 0.5, "enabled" => false } }, body["distances"])
    assert_equal ProcessedMessage.find_by!(idpk: "idpk-dt-1").created_at.iso8601, body["updatedAt"]
  end

  test "a newer distance table updates the destination it repeats" do
    post_event distance_payload("idpk-dt-1", "HGW" => { "distance" => 1500, "transportCost" => 0.25, "enabled" => true })
    post_event distance_payload("idpk-dt-2", "HGW" => { "distance" => 900, "transportCost" => 0.1, "enabled" => false })

    get "/connectivity"

    assert_equal({ "HGW" => { "distance" => 900, "transportCost" => 0.1, "enabled" => false } },
                 response.parsed_body["distances"])
  end

  test "uses CITY_ID for cityId" do
    ENV["CITY_ID"] = "XYZ"

    get "/connectivity"

    assert_equal "XYZ", response.parsed_body["cityId"]
  end

  private

  def post_event(payload)
    post "/events", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  def distance_payload(idpk, distances)
    { "type" => "distance-table", "idpk" => idpk, "msgId" => "msg-#{idpk}", "data" => { "distances" => distances } }
  end
end
