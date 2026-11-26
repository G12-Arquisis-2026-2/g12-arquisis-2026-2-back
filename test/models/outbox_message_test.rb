require "test_helper"

class OutboxMessageTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  def row(created_at, status: "pending")
    msg_id = travel_to(created_at) { publish_outbox(type: "request", data: { ask: "status-statement" }) }
    OutboxMessage.find_by!(msg_id: msg_id).tap { |message| message.update_columns(status: status) }
  end

  test "lag is zero without pending rows" do
    assert_equal({ outbox_oldest_pending_age_seconds: 0, outbox_pending_count: 0, outbox_failed_last_hour: 0 },
                 OutboxMessage.lag)
  end

  test "the age is the one of the oldest pending row" do
    now = Time.current.change(usec: 0) # travel_to trunca los microsegundos
    row(now - 90.seconds)
    row(now - 10.seconds)

    lag = OutboxMessage.lag(now)

    assert_equal 90, lag[:outbox_oldest_pending_age_seconds]
    assert_equal 2, lag[:outbox_pending_count]
  end

  test "sent and failed rows do not count as pending" do
    now = Time.current.change(usec: 0) # travel_to trunca los microsegundos
    row(now - 10.minutes, status: "sent")
    row(now - 5.minutes, status: "failed")
    row(now - 20.seconds)

    lag = OutboxMessage.lag(now)

    assert_equal 20, lag[:outbox_oldest_pending_age_seconds]
    assert_equal 1, lag[:outbox_pending_count]
  end

  test "failed_last_hour counts only the rows that failed in the last hour" do
    now = Time.current.change(usec: 0) # travel_to trunca los microsegundos
    row(now - 3.hours, status: "failed").update_columns(updated_at: now - 2.hours)
    row(now - 30.minutes, status: "failed").update_columns(updated_at: now - 20.minutes)

    assert_equal 1, OutboxMessage.lag(now)[:outbox_failed_last_hour]
  end
end
