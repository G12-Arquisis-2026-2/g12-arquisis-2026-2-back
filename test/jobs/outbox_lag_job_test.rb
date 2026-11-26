require "test_helper"
require "fugit"

class OutboxLagJobTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @logs = []
    @events = []
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  def pending_row(created_at)
    travel_to(created_at) { publish_outbox(type: "request", data: { ask: "status-statement" }) }
  end

  def run_job(agent_started: true, &record)
    record ||= ->(type, attrs) { @events << [type, attrs] }
    with_stub(NewRelic::Agent.singleton_class, :record_custom_event, record) do
      with_stub(OutboxLagJob, :agent_started?, -> { agent_started }) do
        with_stub(Rails.logger.singleton_class, :info, ->(text = nil) { @logs << text.to_s }) { OutboxLagJob.perform_now }
      end
    end
  end

  test "sends the three numbers as an OutboxLag event and logs each send" do
    pending_row(45.seconds.ago)

    run_job

    type, attributes = @events.first
    assert_equal "OutboxLag", type
    assert_in_delta 45, attributes[:outbox_oldest_pending_age_seconds], 1
    assert_equal 1, attributes[:outbox_pending_count]
    assert_equal 0, attributes[:outbox_failed_last_hour]
    assert_equal "TK3", attributes[:cityId]
    assert(@logs.any? { |line| line.include?("[OutboxLag] outbox_oldest_pending_age_seconds=") && line.include?("new_relic=registrado") })
  end

  test "does not fail if New Relic is not available" do
    pending_row(10.seconds.ago)

    run_job { |*| raise IOError, "sin new relic" }

    assert(@logs.any? { |line| line.include?("new_relic=error:IOError") })
  end

  test "without an active agent it only logs" do
    run_job(agent_started: false)

    assert_empty @events
    assert(@logs.any? { |line| line.include?("outbox_oldest_pending_age_seconds=0") && line.include?("new_relic=inactivo") })
  end

  test "runs every 15 seconds and a slow run never piles up the next ones" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "outbox_lag")
    # misma validación que SolidQueue::RecurringTask (sin sus tablas, que en test no existen)
    schedule = Fugit.parse(config["schedule"], multi: :fail)

    assert_equal OutboxLagJob, config["class"].constantize
    assert_instance_of Fugit::Cron, schedule
    assert_equal "0,15,30,45 * * * * *", schedule.to_cron_s
    assert_equal :discard, OutboxLagJob.concurrency_on_conflict
    assert_equal 1, OutboxLagJob.concurrency_limit
  end

  private

  # owner: la clase (método de instancia, también privado) o su singleton_class (método de clase)
  def with_stub(owner, name, replacement)
    backup = :"original_#{name}_for_test"
    owner.alias_method(backup, name)
    owner.define_method(name) { |*args| replacement.call(*args) }
    yield
  ensure
    owner.alias_method(name, backup)
    owner.remove_method(backup)
  end
end
