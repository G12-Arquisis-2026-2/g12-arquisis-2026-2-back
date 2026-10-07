require "test_helper"

# Enunciado § Pago: quien recibe el pago (give) espera el transfer 30 s después de la confirmación;
# si no llega, reintenta la operación con el mismo idpk y un msgId nuevo.
class GiveTransferWaitTest < ActiveJob::TestCase
  self.fixture_table_names = []

  CYCLE_ID = "cycle-transfer-1".freeze
  T0 = Time.utc(2026, 10, 7, 12, 0, 0)

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    travel_to T0
    # Vendible = 1000 - 400 = 600: el give ocupa toda la capacidad, así el reintento solo cabe si no
    # cuenta su propia confirmación como energía ya vendida.
    @cycle = Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 1000, consumption: 400, generation_cost: 10,
                           valid_until: T0 + 1.hour)
    payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 600)
    @proposal = Proposal.create!(idpk: payload[:idpk], cycle_id: CYCLE_ID, direction: "give", quantity: 600,
                                 price_per_energy: 10.5, generation_cost: 10, status: :pending)
    @proposal_msg_id = RabbitMQPublisher.publish(payload)
  end

  teardown do
    travel_back
    ENV["CITY_ID"] = @previous_city
  end

  test "the give confirmation records confirmed_at and schedules the transfer wait 30 s later" do
    confirm!

    @proposal.reload
    assert @proposal.confirmed?
    assert_equal T0, @proposal.confirmed_at
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [@proposal.idpk, { transfer_attempt: 0 }], at: T0 + 30.seconds)
  end

  test "without transfer, at 30 s exactly one message goes out with the same idpk, same energy and a new msgId" do
    confirm!
    original = proposal_messages.first

    travel_to T0 + 29.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end

    travel_to T0 + 30.seconds
    assert_difference -> { proposal_messages.count }, 1 do
      run_due_jobs
    end

    retried = proposal_messages.last
    assert_equal @proposal.idpk, retried.idpk
    assert_not_equal original.msg_id, retried.msg_id
    assert_not_equal retried.idpk, retried.msg_id
    assert_equal({ "direction" => "give", "quantity" => 600.0, "pricePerEnergy" => 10.5 }, retried.payload["data"])
    assert_equal original.payload["data"], retried.payload["data"]

    @proposal.reload
    assert @proposal.confirmed?
    assert_equal 1, @proposal.transfer_retries
    assert_equal T0 + 30.seconds, @proposal.last_transfer_retry_at
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [@proposal.idpk, { transfer_attempt: 1 }], at: T0 + 60.seconds)
  end

  test "a transfer that arrives in time marks the proposal paid and stops the wait" do
    give_msg_id = confirm!

    travel_to T0 + 10.seconds
    pay!(give_msg_id)
    assert @proposal.reload.paid?

    travel_to T0 + 30.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end
    assert @proposal.reload.paid?
    assert_equal 0, @proposal.transfer_retries
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a transfer whose becauseOf is the confirmation counts as paid even if the ledger did not mark it" do
    give_msg_id = confirm!
    Transaction.create!(idpk: "central-transfer-x", cycle_id: CYCLE_ID, operation_type: "transfer",
                        energy_change: 0, budget_change: 6300,
                        raw_data: { "type" => "transfer", "data" => { "becauseOf" => give_msg_id, "quantity" => 6300 } })

    travel_to T0 + 30.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end
    assert @proposal.reload.paid?
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a transfer that arrives after a retry stops the following retries" do
    confirm!
    travel_to T0 + 30.seconds
    run_due_jobs
    regive_msg_id = confirm!(proposal_messages.last.msg_id, idpk: "central-give-2")

    travel_to T0 + 45.seconds
    pay!(regive_msg_id)

    travel_to T0 + 60.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end
    assert @proposal.reload.paid?
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "after 3 retries without transfer the proposal fails with a reason and nothing else is published" do
    confirm!

    1.upto(Proposal::MAX_TRANSFER_RETRIES) do |n|
      travel_to T0 + (30 * n).seconds
      assert_difference -> { proposal_messages.count }, 1 do
        run_due_jobs
      end
    end
    assert_equal 3, @proposal.reload.transfer_retries

    travel_to T0 + 120.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end

    @proposal.reload
    assert @proposal.failed?
    assert_equal "FAILED", @proposal.status_before_type_cast
    assert_equal "Transfer no recibido tras 3 reintentos", @proposal.status_reason
    assert_no_enqueued_jobs only: NegotiationTimeoutJob

    travel_to T0 + 150.seconds
    assert_no_difference -> { proposal_messages.count } do
      NegotiationTimeoutJob.perform_now(@proposal.idpk, transfer_attempt: 3)
    end
    assert @proposal.reload.failed?
  end

  test "a closed cycle window does not retry and closes the proposal" do
    confirm!
    @cycle.update!(valid_until: T0 + 20.seconds)

    travel_to T0 + 30.seconds
    assert_no_difference -> { proposal_messages.count } do
      run_due_jobs
    end

    @proposal.reload
    assert @proposal.failed?
    assert_equal "Transfer no recibido antes del cierre de la ventana del ciclo #{CYCLE_ID} (0 reintentos)",
                 @proposal.status_reason
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a pending retry still in the outbox is voided when the proposal closes" do
    confirm!
    travel_to T0 + 30.seconds
    run_due_jobs
    pending_retry = proposal_messages.last
    @cycle.update!(valid_until: T0 + 50.seconds)

    travel_to T0 + 60.seconds
    run_due_jobs

    assert @proposal.reload.failed?
    assert_equal "failed", pending_retry.reload.status
  end

  test "duplicate jobs for the same wait publish a single retry and keep a single follow-up" do
    confirm!
    2.times { NegotiationTimeoutJob.perform_later(@proposal.idpk, transfer_attempt: 0) }

    travel_to T0 + 30.seconds
    assert_difference -> { proposal_messages.count }, 1 do
      run_due_jobs
    end

    follow_ups = enqueued_jobs.select { |job| job["job_class"] == "NegotiationTimeoutJob" }
    assert_equal 1, follow_ups.size
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [@proposal.idpk, { transfer_attempt: 1 }])
  end

  test "a job that runs before 30 s does not retry and checks again when they are up" do
    confirm!
    clear_enqueued_jobs

    travel_to T0 + 29.seconds
    assert_no_difference -> { proposal_messages.count } do
      NegotiationTimeoutJob.perform_now(@proposal.idpk, transfer_attempt: 0)
    end
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [@proposal.idpk, { transfer_attempt: 0 }], at: T0 + 30.seconds)
  end

  test "the confirmation of a retry does not start a second wait" do
    confirm!
    travel_to T0 + 30.seconds
    run_due_jobs
    clear_enqueued_jobs

    confirm!(proposal_messages.last.msg_id, idpk: "central-give-2")

    assert_no_enqueued_jobs only: NegotiationTimeoutJob
    assert_equal T0, @proposal.reload.confirmed_at
  end

  test "closed proposals are never retried nor overwritten" do
    confirm!
    clear_enqueued_jobs
    travel_to T0 + 30.seconds

    %i[paid rejected expired failed].each do |status|
      @proposal.update!(status: status, status_reason: "motivo original")

      assert_no_difference -> { proposal_messages.count } do
        NegotiationTimeoutJob.perform_now(@proposal.idpk, transfer_attempt: 0)
      end
      @proposal.reload
      assert_equal status.to_s, @proposal.status
      assert_equal "motivo original", @proposal.status_reason
    end
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a retry that cannot be built closes the proposal as failed" do
    confirm!
    @cycle.update!(generation_capacity: 100) # ya no queda capacidad vendible: OVER_CAPACITY local

    travel_to T0 + 30.seconds
    assert_nothing_raised { run_due_jobs }

    @proposal.reload
    assert @proposal.failed?
    assert_match(/\AReintento por transfer fallido \(OverCapacityError\)/, @proposal.status_reason)
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  test "a take confirmation does not wait for a transfer" do
    take = Proposal.create!(idpk: "take-idpk-1", cycle_id: CYCLE_ID, direction: "take", quantity: 50,
                            price_per_energy: 10, generation_cost: 10, status: :pending)

    take.update!(status: :confirmed)

    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  private

  # Confirmación give de la central (data.target = msgId de nuestra propuesta), por el ledger real.
  def confirm!(target = @proposal_msg_id, idpk: "central-give-1")
    msg_id = SecureRandom.uuid
    LedgerProcessorService.call(
      "idpk" => idpk, "msgId" => msg_id, "type" => "give", "cycleId" => CYCLE_ID,
      "data" => { "target" => target, "energy" => 600, "pricePerEnergy" => 10.5 }
    )
    msg_id
  end

  # Transfer de pago de la central (data.becauseOf = msgId de la confirmación give).
  def pay!(give_msg_id)
    LedgerProcessorService.call(
      "idpk" => "central-transfer-#{give_msg_id}", "msgId" => SecureRandom.uuid, "type" => "transfer",
      "cycleId" => CYCLE_ID, "data" => { "becauseOf" => give_msg_id, "quantity" => 6300 }
    )
  end

  def proposal_messages
    OutboxMessage.where(idpk: @proposal.idpk, message_type: "negotiation-proposal").order(:id)
  end

  # Ejecuta los jobs de NegotiationTimeoutJob cuyo momento ya llegó (sin sleep: el tiempo lo mueve travel_to).
  def run_due_jobs
    perform_enqueued_jobs(only: NegotiationTimeoutJob, at: Time.current)
  end
end
