require "test_helper"

class CycleServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  # Ventana de negociación del ciclo: [14:00, 14:20). Periodo de cierre: [14:15, 14:20).
  # La siguiente ventana esperada abre a las 16:00.
  VALID_UNTIL = Time.utc(2026, 10, 7, 14, 20)

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    # con tabla de distancias, para que los tests de status no vean peticiones de distance-table
    DistanceTable.create!(destination_code: "HGW", distance: 1, transport_cost: 0.1, enabled: true)
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  # --- petición directa ---

  test "the direct request has data.ask as a plain string" do
    %w[status-statement distance-table].each do |ask|
      assert_equal({ ask: ask }, CycleService.build_direct_request(ask: ask)[:data])

      msg_id = RabbitMQPublisher.publish(CycleService.build_direct_request(ask: ask))
      payload = OutboxMessage.find_by!(msg_id: msg_id).payload
      assert_equal "request", payload["type"]
      assert_equal({ "ask" => ask }, payload["data"])
      assert_equal "TK3", payload["cityId"]
    end
  end

  # --- status-statement ---

  test "cold start asks for the status at most 3 times with growing backoff" do
    start = Time.utc(2026, 10, 7, 10, 0)

    travel_to(start) { assert_equal start + 1.minute, CycleService.tick }
    travel_to(start + 30.seconds) { CycleService.tick }
    assert_equal 1, requests("status-statement").count

    travel_to(start + 1.minute) { CycleService.tick }
    travel_to(start + 3.minutes) { CycleService.tick }
    assert_equal 2, requests("status-statement").count

    travel_to(start + 4.minutes) { CycleService.tick }
    (5..110).step(5) { |minute| travel_to(start + minute.minutes) { CycleService.tick } }
    assert_equal 3, requests("status-statement").count

    # pasado un ciclo completo sin respuesta se vuelve a intentar
    travel_to(start + 2.hours + 1.second) { CycleService.tick }
    assert_equal 4, requests("status-statement").count
  end

  test "does not ask for the status while the current cycle is known" do
    create_cycle("cycle-1")

    [VALID_UNTIL - 19.minutes, VALID_UNTIL, VALID_UNTIL + 90.minutes].each do |now|
      travel_to(now) { CycleService.tick }
    end

    assert_equal 0, requests("status-statement").count
  end

  test "asks for the missing status of the next window, at most 3 times" do
    create_cycle("cycle-1")
    next_open = VALID_UNTIL + 100.minutes # 16:00

    travel_to(next_open + 30.seconds) { CycleService.tick }
    assert_equal 0, requests("status-statement").count, "espera primero a que llegue solo"

    [1, 2, 3, 5, 6, 10, 19].each { |minute| travel_to(next_open + minute.minutes) { CycleService.tick } }
    times = requests("status-statement").order(:created_at).pluck(:created_at)
    assert_equal [next_open + 1.minute, next_open + 2.minutes, next_open + 5.minutes], times
  end

  test "stops asking once the new status arrives" do
    create_cycle("cycle-1")
    next_open = VALID_UNTIL + 100.minutes

    travel_to(next_open + 1.minute) { CycleService.tick }
    create_cycle("cycle-2", valid_until: next_open + 20.minutes)
    travel_to(next_open + 3.minutes) { CycleService.tick }

    assert_equal 1, requests("status-statement").count
  end

  test "a window that passes without status is skipped until the next one" do
    create_cycle("cycle-1")
    next_open = VALID_UNTIL + 100.minutes

    [1, 2, 5, 30, 90, 120].each { |minute| travel_to(next_open + minute.minutes) { CycleService.tick } }
    assert_equal 3, requests("status-statement").count

    travel_to(next_open + 2.hours + 1.minute) { CycleService.tick }
    assert_equal 4, requests("status-statement").count
  end

  test "asks for the distance table when there is none, without spamming" do
    DistanceTable.delete_all
    create_cycle("cycle-1")
    start = VALID_UNTIL - 15.minutes

    (0..10).each { |minute| travel_to(start + minute.minutes) { CycleService.tick } }

    assert_equal 3, requests("distance-table").count
  end

  # --- negotiation-report ---

  test "the report waits for the closing period and is sent once with ledger balances" do
    cycle = create_cycle("cycle-1")
    ledger("cycle-1", energy: 1500, budget: -322_500)
    ledger("cycle-1", energy: 0, budget: 508_145)
    ledger("other-cycle", energy: 99, budget: 99) # su budget se arrastra, su energía no

    travel_to(VALID_UNTIL - 6.minutes) { assert_equal VALID_UNTIL - 5.minutes, CycleService.tick }
    assert_equal 0, reports.count

    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    travel_to(VALID_UNTIL - 4.minutes) { CycleService.tick }

    assert_equal 1, reports.count
    payload = reports.first.payload
    assert_equal "negotiation-report", payload["type"]
    assert_equal "cycle-1", payload["cycleId"]
    # budget: -322500 + 508145 + 99; energía: (10 - 5) del status-statement + 1500
    assert_equal({ "budgetBalance" => 185_744.0, "energyBalance" => 1505.0 }, payload["data"])
    assert_equal payload["idpk"], cycle.reload.report_idpk
    assert_equal payload["msgId"], cycle.report_msg_id
  end

  test "a ledger change during the closing period sends a correction with a new idpk" do
    create_cycle("cycle-1")
    ledger("cycle-1", energy: 10, budget: 100)
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }

    ledger("cycle-1", energy: -4, budget: 60)
    travel_to(VALID_UNTIL - 4.minutes) { CycleService.tick }

    first, correction = reports.order(:id).map(&:payload)
    assert_equal({ "budgetBalance" => 160.0, "energyBalance" => 11.0 }, correction["data"])
    assert_not_equal first["idpk"], correction["idpk"]
    assert_not_equal first["msgId"], correction["msgId"]
  end

  test "REPORT_TOO_EARLY reschedules the same report for opensAt, same idpk and new msgId" do
    cycle = create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    first = reports.first.payload
    opens_at = VALID_UNTIL - 3.minutes

    AuditedEventService.call(central_error("REPORT_TOO_EARLY", target: first["msgId"], opensAt: opens_at.iso8601))
    assert_equal opens_at, cycle.reload.report_not_before

    travel_to(VALID_UNTIL - 4.minutes) { assert_equal opens_at, CycleService.tick }
    assert_equal 1, reports.count

    travel_to(opens_at) { CycleService.tick }
    retry_payload = reports.order(:id).last.payload
    assert_equal 2, reports.count
    assert_equal first["idpk"], retry_payload["idpk"]
    assert_not_equal first["msgId"], retry_payload["msgId"]
    assert_nil cycle.reload.report_not_before
  end

  test "a repeated REPORT_TOO_EARLY error (same idpk) is processed only once" do
    cycle = create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    error = central_error("REPORT_TOO_EARLY", target: reports.first.msg_id, opensAt: (VALID_UNTIL - 3.minutes).iso8601)

    AuditedEventService.call(error)
    cycle.reload.update!(report_not_before: nil)
    assert_equal false, AuditedEventService.call(error)

    assert_nil cycle.reload.report_not_before
  end

  test "never sends the report late and leaves a record instead" do
    create_cycle("cycle-1")

    travel_to(VALID_UNTIL - 20.seconds) { CycleService.tick }
    assert_equal 0, reports.count

    travel_to(VALID_UNTIL + 10.seconds) { CycleService.tick }
    travel_to(VALID_UNTIL + 1.minute) { CycleService.tick }

    assert_equal 0, reports.count
    missed = AuditLog.where(event_type: "REPORT_MISSED")
    assert_equal 1, missed.count
    assert_includes missed.first.reason, "cycle-1"
    assert_not_nil Cycle.find_by!(cycle_id: "cycle-1").report_missed_at
  end

  test "a report rejected as too early and never retried counts as missed" do
    create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    reports.first.mark_sent!
    AuditedEventService.call(central_error("REPORT_TOO_EARLY", target: reports.first.msg_id,
                                                               opensAt: (VALID_UNTIL + 1.minute).iso8601))

    travel_to(VALID_UNTIL + 10.seconds) { CycleService.tick }

    assert_equal 1, reports.count
    assert_equal 1, AuditLog.where(event_type: "REPORT_MISSED").count
  end

  test "a delivered report is not recorded as missed" do
    create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    reports.first.mark_sent!

    travel_to(VALID_UNTIL + 10.seconds) { CycleService.tick }

    assert_equal 0, AuditLog.where(event_type: "REPORT_MISSED").count
  end

  test "the outbox keeps a report of an unknown cycle" do
    msg_id = RabbitMQPublisher.publish(type: "negotiation-report", cycleId: "cycle-desconocido", data: {})

    OutboxMessage.expire_late_reports!

    assert_equal "pending", OutboxMessage.find_by!(msg_id: msg_id).status
  end

  test "the outbox drops a report whose window closed before it was published" do
    create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    report = reports.first

    travel_to(VALID_UNTIL - 1.minute) { OutboxMessage.expire_late_reports! }
    assert_equal "pending", report.reload.status

    travel_to(VALID_UNTIL - 2.seconds) { OutboxMessage.expire_late_reports! }
    assert_equal "failed", report.reload.status
    assert_includes report.error, "CYCLE_WINDOW_CLOSED"
  end

  private

  def create_cycle(cycle_id, valid_until: VALID_UNTIL)
    Cycle.create!(cycle_id: cycle_id, valid_until: valid_until, generation_capacity: 10, consumption: 5,
                  generation_cost: 1)
  end

  def ledger(cycle_id, energy:, budget:)
    Transaction.create!(idpk: SecureRandom.uuid, cycle_id: cycle_id, operation_type: "test",
                        energy_change: energy, budget_change: budget, raw_data: { "type" => "test" })
  end

  def requests(ask)
    OutboxMessage.where(message_type: "request").where("payload -> 'data' ->> 'ask' = ?", ask)
  end

  def reports
    OutboxMessage.where(message_type: "negotiation-report")
  end

  def central_error(reason, target:, opensAt:)
    {
      "type" => "error", "idpk" => SecureRandom.uuid, "msgId" => SecureRandom.uuid, "sender" => "central",
      "reason" => reason, "code" => 425, "data" => { "target" => target, "opensAt" => opensAt }
    }
  end
end
