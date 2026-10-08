require "test_helper"

# Mensajes `error` de la central sobre una propuesta de negociación (POST /events, como los entrega el connector)
class CentralErrorEventsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  self.fixture_table_names = []

  CYCLE_ID = "cycle-neg-1".freeze
  PROPOSAL_IDPK = "proposal-idpk-1".freeze

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 1000, consumption: 400, generation_cost: 10,
                  valid_until: 1.hour.from_now)
    @proposal = Proposal.create!(idpk: PROPOSAL_IDPK, cycle_id: CYCLE_ID, direction: "give", quantity: 100,
                                 price_per_energy: 10.5, generation_cost: 10, status: :pending)
    @msg_id = publish_proposal
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  {
    "PRICE_ABOVE_CAP" => [422, { "cap" => 10.5 }, "PRICE_ABOVE_CAP (422): precio sobre el tope [cap=10.5]"],
    "OVER_CAPACITY" => [409, { "spare" => 200 }, "OVER_CAPACITY (409): precio sobre el tope [spare=200]"],
    "CYCLE_EXPIRED" => [410, {}, "CYCLE_EXPIRED (410): precio sobre el tope"],
    "CYCLE_UNKNOWN" => [404, {}, "CYCLE_UNKNOWN (404): precio sobre el tope"]
  }.each do |reason, (code, extra, expected_reason)|
    test "#{reason} rejects the proposal with its reason and leaves an audit log" do
      post_event central_error(reason, code, @msg_id, extra)

      assert_response :created
      @proposal.reload
      assert @proposal.rejected?
      assert_equal "REJECTED", @proposal.status_before_type_cast
      assert_equal expected_reason, @proposal.status_reason
      log = AuditLog.find_by!(event_type: "CENTRAL_ERROR")
      assert_equal reason, log.reason
      assert_equal @msg_id, log.raw_payload.dig("data", "target")
    end
  end

  test "the error never produces an ACK or NACK towards the central" do
    assert_no_difference -> { OutboxMessage.count } do
      post_event central_error("PRICE_ABOVE_CAP", 422, @msg_id, "cap" => 10.5)
    end
    assert_equal 0, OutboxMessage.where(message_type: %w[ack nack]).count
    assert_equal 0, AuditLog.where(event_type: "NACK").count
  end

  test "a rejected proposal is not retried by the timeout job" do
    post_event central_error("OVER_CAPACITY", 409, @msg_id, "spare" => 200)

    assert_no_difference -> { OutboxMessage.where(message_type: "negotiation-proposal").count } do
      NegotiationTimeoutJob.perform_now(PROPOSAL_IDPK)
    end
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
    assert @proposal.reload.rejected?
  end

  test "an error for an earlier retry also matches the proposal (same idpk, new msgId)" do
    retry_msg_id = publish_proposal

    post_event central_error("CYCLE_EXPIRED", 410, @msg_id)

    assert @proposal.reload.rejected?
    # el reintento que aún no salía del outbox ya no se publica
    assert_equal "failed", OutboxMessage.find_by!(msg_id: retry_msg_id).status
  end

  test "a repeated error idpk is processed once" do
    error = central_error("PRICE_ABOVE_CAP", 422, @msg_id, "cap" => 10.5)
    post_event error
    post_event error

    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR").count
    assert_equal 1, AuditLog.where(event_type: "DUPLICATE", idpk: error["idpk"]).count
  end

  test "an error does not overwrite a proposal already confirmed" do
    @proposal.confirmed!

    post_event central_error("CYCLE_EXPIRED", 410, @msg_id)

    assert_response :created
    assert @proposal.reload.confirmed?
    assert_nil @proposal.status_reason
  end

  test "an error whose target is not a proposal is only logged" do
    post_event central_error("CYCLE_UNKNOWN", 404, SecureRandom.uuid)

    assert_response :created
    assert @proposal.reload.pending?
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR", reason: "CYCLE_UNKNOWN").count
  end

  test "the target is the msgId, never the proposal idpk" do
    post_event central_error("CYCLE_UNKNOWN", 404, PROPOSAL_IDPK)

    assert @proposal.reload.pending?
  end

  test "an error without data is still logged" do
    post_event({ "type" => "error", "idpk" => SecureRandom.uuid, "msgId" => SecureRandom.uuid,
                 "reason" => "OVER_CAPACITY", "code" => 409 })

    assert_response :created
    assert @proposal.reload.pending?
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR").count
  end

  private

  def publish_proposal
    RabbitMQPublisher.publish(
      { type: "negotiation-proposal", cycleId: CYCLE_ID,
        data: { direction: "give", quantity: 100, pricePerEnergy: 10.5 } },
      idpk: PROPOSAL_IDPK
    )
  end

  def central_error(reason, code, target, extra = {})
    {
      "type" => "error", "idpk" => SecureRandom.uuid, "msgId" => SecureRandom.uuid,
      "timestamp" => Time.current.iso8601, "reason" => reason, "code" => code,
      "data" => { "target" => target, "message" => "precio sobre el tope" }.merge(extra)
    }
  end

  def post_event(payload)
    post "/events", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end
end
