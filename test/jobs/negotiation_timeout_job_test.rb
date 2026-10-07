require "test_helper"

class NegotiationTimeoutJobTest < ActiveJob::TestCase
  self.fixture_table_names = []

  CYCLE_ID = "cycle-timeout-1".freeze

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @cycle = Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 1000, consumption: 400, generation_cost: 10,
                           valid_until: 1.hour.from_now)
    @proposal = Proposal.create!(idpk: "timeout-idpk-1", cycle_id: CYCLE_ID, direction: "give", quantity: 100,
                                 price_per_energy: 10.5, generation_cost: 10, status: :pending)
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "a closed window marks the proposal expired by timeout and stops retrying" do
    @cycle.update!(valid_until: 1.minute.ago)
    pending_retry = OutboxMessage.create!(msg_id: SecureRandom.uuid, idpk: @proposal.idpk,
                                          message_type: "negotiation-proposal", payload: { "type" => "negotiation-proposal" })

    assert_no_difference -> { OutboxMessage.count } do
      NegotiationTimeoutJob.perform_now(@proposal.idpk)
    end

    @proposal.reload
    assert @proposal.expired?
    assert_equal "EXPIRED", @proposal.status_before_type_cast
    assert_match(/Expirada por timeout/, @proposal.status_reason)
    assert_equal "failed", pending_retry.reload.status
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "an unknown cycle also expires the proposal" do
    @cycle.destroy!

    NegotiationTimeoutJob.perform_now(@proposal.idpk)

    assert @proposal.reload.expired?
  end

  test "a retry that cannot be built marks the proposal failed instead of raising" do
    with_build_proposal_raising(NegotiationService::OverCapacityError.new("sin capacidad")) do
      assert_nothing_raised { NegotiationTimeoutJob.perform_now(@proposal.idpk) }
    end

    @proposal.reload
    assert @proposal.failed?
    assert_equal "FAILED", @proposal.status_before_type_cast
    assert_equal "Reintento fallido (OverCapacityError): sin capacidad", @proposal.status_reason
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a proposal that is no longer pending is not retried" do
    %i[rejected expired failed confirmed paid].each do |status|
      @proposal.update!(status: status)

      assert_no_difference -> { OutboxMessage.count } do
        NegotiationTimeoutJob.perform_now(@proposal.idpk)
      end
      assert_equal status.to_s, @proposal.reload.status
    end
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a pending proposal in an open window is retried with the same idpk" do
    NegotiationTimeoutJob.perform_now(@proposal.idpk)

    retry_message = OutboxMessage.find_by!(message_type: "negotiation-proposal")
    assert_equal @proposal.idpk, retry_message.idpk
    assert_not_equal @proposal.idpk, retry_message.msg_id
    assert @proposal.reload.pending?
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [@proposal.idpk])
  end

  test "the retry publishes the same idpk and the same energy with a new msgId" do
    first = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 100,
                                              existing_idpk: @proposal.idpk)
    first_msg_id = RabbitMQPublisher.publish(first)

    assert_difference -> { OutboxMessage.where(message_type: "negotiation-proposal").count }, 1 do
      NegotiationTimeoutJob.perform_now(@proposal.idpk)
    end

    original, retried = OutboxMessage.where(message_type: "negotiation-proposal").order(:id).to_a
    assert_equal first_msg_id, original.msg_id
    assert_equal original.idpk, retried.idpk
    assert_equal @proposal.idpk, retried.idpk
    assert_not_equal original.msg_id, retried.msg_id
    assert_equal 100.0, retried.payload.dig("data", "quantity")
    assert_equal original.payload["data"], retried.payload["data"]
    assert_equal 100, @proposal.reload.quantity
  end

  test "a take is retried even above own capacity" do
    @proposal.update!(direction: "take", quantity: 5000, price_per_energy: 10)

    NegotiationTimeoutJob.perform_now(@proposal.idpk)

    retried = OutboxMessage.find_by!(message_type: "negotiation-proposal")
    assert_equal({ "direction" => "take", "quantity" => 5000.0, "pricePerEnergy" => 10.0 }, retried.payload["data"])
    assert @proposal.reload.pending?
  end

  private

  def with_build_proposal_raising(error)
    original = NegotiationService.method(:build_proposal)
    NegotiationService.define_singleton_method(:build_proposal) { |**_args| raise error }
    yield
  ensure
    NegotiationService.define_singleton_method(:build_proposal, original)
  end
end
