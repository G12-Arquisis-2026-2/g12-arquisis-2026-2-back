require "test_helper"

# Regresión: en un take pagamos nosotros y emitimos el transfer una sola vez, aunque la confirmación
# take llegue duplicada (mismo idpk) o se reprocese. Tampoco queda esperando un transfer de la central.
class TakeSingleTransferTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  self.fixture_table_names = []

  CYCLE_ID = "cycle-take-1".freeze

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 100, consumption: 400, generation_cost: 10,
                  valid_until: 1.hour.from_now)
    payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "take", energy: 300)
    @proposal = Proposal.create!(idpk: payload[:idpk], cycle_id: CYCLE_ID, direction: "take", quantity: 300,
                                 price_per_energy: 10, generation_cost: 10, status: :pending)
    @proposal_msg_id = RabbitMQPublisher.publish(payload)
    @take = {
      "type" => "take", "idpk" => "central-take-1", "msgId" => SecureRandom.uuid, "cycleId" => CYCLE_ID,
      "data" => { "target" => @proposal_msg_id, "energy" => 300, "pricePerEnergy" => 10 }
    }
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "a take delivered twice with the same idpk emits a single transfer" do
    post_event @take
    assert_response :created

    post_event @take
    assert_response :ok
    assert_equal "duplicate", response.parsed_body["status"]

    # reenvío de la central: mismo idpk, msgId nuevo
    post_event @take.merge("msgId" => SecureRandom.uuid)
    assert_response :ok

    assert_single_transfer
    assert_equal 2, AuditLog.where(idpk: "central-take-1", event_type: "DUPLICATE").count
  end

  test "reprocessing the same take does not emit a second transfer" do
    2.times { LedgerProcessorService.call(@take) }

    assert_single_transfer
  end

  private

  def assert_single_transfer
    transfers = OutboxMessage.where(message_type: "transfer")
    assert_equal 1, transfers.count
    assert_equal({ "becauseOf" => @take["msgId"], "quantity" => 3000.0 }, transfers.first.payload["data"])
    assert_equal 1, Transaction.where(idpk: "central-take-1").count
    assert @proposal.reload.paid?
    assert_nil @proposal.confirmed_at
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  def post_event(payload)
    post "/events", params: payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end
end
