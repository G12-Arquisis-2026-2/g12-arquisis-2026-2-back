require "test_helper"

class CycleOrchestratorJobTest < ActiveJob::TestCase
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "without cycles it asks for the status and keeps the chain alive" do
    now = Time.utc(2026, 10, 7, 10, 0)

    travel_to(now) do
      assert_nothing_raised { CycleOrchestratorJob.perform_now }

      assert_enqueued_with(job: CycleOrchestratorJob, at: now + 1.minute)
    end
    asks = OutboxMessage.where(message_type: "request").map { |request| request.payload["data"] }
    assert_equal [{ "ask" => "distance-table" }, { "ask" => "status-statement" }], asks.sort_by { |data| data["ask"] }
  end

  test "a failing tick is logged and the chain is rescheduled" do
    now = Time.utc(2026, 10, 7, 10, 0)
    original = CycleService.method(:tick)
    CycleService.define_singleton_method(:tick) { |*_args| raise ActiveRecord::ConnectionNotEstablished, "db down" }

    travel_to(now) do
      assert_nothing_raised { CycleOrchestratorJob.perform_now }

      assert_enqueued_with(job: CycleOrchestratorJob, at: now + CycleOrchestratorJob::ERROR_RETRY)
    end
  ensure
    CycleService.define_singleton_method(:tick, original)
  end

  test "the job sends the report inside the closing period" do
    Cycle.create!(cycle_id: "cycle-1", valid_until: Time.utc(2026, 10, 7, 14, 20))

    travel_to(Time.utc(2026, 10, 7, 14, 16)) { CycleOrchestratorJob.perform_now }

    report = OutboxMessage.find_by!(message_type: "negotiation-report")
    assert_equal "cycle-1", report.payload["cycleId"]
  end

  test "start_chain enqueues when nothing is scheduled" do
    assert CycleOrchestratorJob.start_chain
    assert_enqueued_jobs 1, only: CycleOrchestratorJob
  end

  test "start_chain does not add a second chain" do
    with_already_scheduled(true) do
      assert_not CycleOrchestratorJob.start_chain
    end
    assert_no_enqueued_jobs only: CycleOrchestratorJob
  end

  # Con Solid Queue (producción) los jobs viven en la BD: se carga su schema dentro de la transacción
  # del test (en Postgres el DDL también se revierte al terminar).
  test "with solid queue, a pending or scheduled job counts as scheduled but a failed one does not" do
    ActiveRecord::Schema.verbose = false
    load Rails.root.join("db/queue_schema.rb")
    previous_adapter = CycleOrchestratorJob.queue_adapter
    CycleOrchestratorJob.queue_adapter = :solid_queue

    assert_not CycleOrchestratorJob.already_scheduled?
    assert CycleOrchestratorJob.start_chain
    assert_not CycleOrchestratorJob.start_chain, "un reinicio no debe encolar otra cadena"
    assert_equal 1, SolidQueue::Job.where(class_name: "CycleOrchestratorJob").count

    CycleOrchestratorJob.set(wait: 2.hours).perform_later
    SolidQueue::Job.where(class_name: "CycleOrchestratorJob").find_each do |job|
      job.update!(finished_at: Time.current) unless job.scheduled_execution
    end
    assert CycleOrchestratorJob.already_scheduled?, "el programado para más tarde cuenta"

    SolidQueue::Job.where(class_name: "CycleOrchestratorJob").find_each do |job|
      job.scheduled_execution&.destroy!
      SolidQueue::FailedExecution.create!(job: job, error: { "exception_class" => "RuntimeError" }) unless job.finished_at
    end
    assert_not CycleOrchestratorJob.already_scheduled?, "un job fallido no debe bloquear la cadena"
  ensure
    CycleOrchestratorJob.queue_adapter = previous_adapter if previous_adapter
  end

  private

  def with_already_scheduled(value)
    original = CycleOrchestratorJob.method(:already_scheduled?)
    CycleOrchestratorJob.define_singleton_method(:already_scheduled?) { value }
    yield
  ensure
    CycleOrchestratorJob.define_singleton_method(:already_scheduled?, original)
  end
end
