require "test_helper"

# Lo que hacía AuditedEventService con un `error` de la central y que ErrorProcessorService debe conservar
# para todos los errores, también los que apuntan a un negotiation-report (no a una propuesta):
# (a) AuditLog CENTRAL_ERROR con raw_payload y (b) REPORT_TOO_EARLY reprograma el reporte desde data.opensAt.
class ErrorProcessorServiceTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  VALID_UNTIL = Time.utc(2026, 10, 7, 14, 20)

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @cycle = Cycle.create!(cycle_id: "cycle-report-1", valid_until: VALID_UNTIL, generation_capacity: 10,
                           consumption: 5, generation_cost: 1)
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    @report = OutboxMessage.find_by!(message_type: "negotiation-report")
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "REPORT_TOO_EARLY to a report leaves the audit log and reschedules the report" do
    opens_at = VALID_UNTIL - 3.minutes
    error = central_error("REPORT_TOO_EARLY", 425, @report.msg_id, "opensAt" => opens_at.iso8601)

    assert ErrorProcessorService.call(error)

    assert_equal opens_at, @cycle.reload.report_not_before
    log = AuditLog.find_by!(event_type: "CENTRAL_ERROR")
    assert_equal "REPORT_TOO_EARLY", log.reason
    assert_equal error["idpk"], log.idpk
    assert_equal error, log.raw_payload
  end

  test "after REPORT_TOO_EARLY the report is sent again at opensAt with the same idpk" do
    opens_at = VALID_UNTIL - 3.minutes
    ErrorProcessorService.call(central_error("REPORT_TOO_EARLY", 425, @report.msg_id, "opensAt" => opens_at.iso8601))

    travel_to(VALID_UNTIL - 4.minutes) { CycleService.tick }
    assert_equal 1, reports.count

    travel_to(opens_at) { CycleService.tick }
    retried = reports.order(:id).last
    assert_equal 2, reports.count
    assert_equal @report.idpk, retried.idpk
    assert_not_equal @report.msg_id, retried.msg_id
  end

  test "REPORT_TOO_EARLY through POST /events also reschedules the report" do
    opens_at = VALID_UNTIL - 3.minutes

    post "/events", params: central_error("REPORT_TOO_EARLY", 425, @report.msg_id, "opensAt" => opens_at.iso8601).to_json,
                    headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :created
    assert_equal opens_at, @cycle.reload.report_not_before
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR", reason: "REPORT_TOO_EARLY").count
  end

  {
    "CYCLE_EXPIRED" => 410, "CYCLE_UNKNOWN" => 404, "MALFORMED_MESSAGE" => 422,
    "PRICE_ABOVE_CAP" => 422, "OVER_CAPACITY" => 409
  }.each do |reason, code|
    test "#{reason} to a report leaves the audit log and does not touch the cycle nor proposals" do
      proposal = Proposal.create!(idpk: SecureRandom.uuid, cycle_id: @cycle.cycle_id, direction: "give",
                                  quantity: 1, price_per_energy: 1.05, generation_cost: 1, status: :pending)
      error = central_error(reason, code, @report.msg_id)

      assert_no_changes -> { @cycle.reload.attributes } do
        assert ErrorProcessorService.call(error)
      end

      log = AuditLog.find_by!(event_type: "CENTRAL_ERROR")
      assert_equal reason, log.reason
      assert_equal error, log.raw_payload
      assert proposal.reload.pending?
      assert_equal "pending", @report.reload.status
    end
  end

  test "a REPORT_TOO_EARLY with an invalid opensAt is still logged" do
    assert ErrorProcessorService.call(central_error("REPORT_TOO_EARLY", 425, @report.msg_id, "opensAt" => "mañana"))

    assert_nil @cycle.reload.report_not_before
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR").count
  end

  test "a repeated error idpk is processed once" do
    error = central_error("REPORT_TOO_EARLY", 425, @report.msg_id, "opensAt" => (VALID_UNTIL - 3.minutes).iso8601)

    ErrorProcessorService.call(error)
    @cycle.reload.update!(report_not_before: nil)
    assert_equal false, ErrorProcessorService.call(error)

    assert_nil @cycle.reload.report_not_before
    assert_equal 1, AuditLog.where(event_type: "CENTRAL_ERROR").count
  end

  test "an error never publishes an ACK or NACK" do
    assert_no_difference -> { OutboxMessage.count } do
      ErrorProcessorService.call(central_error("CYCLE_EXPIRED", 410, @report.msg_id))
    end
  end

  private

  def reports
    OutboxMessage.where(message_type: "negotiation-report")
  end

  def central_error(reason, code, target, extra = {})
    {
      "type" => "error", "idpk" => SecureRandom.uuid, "msgId" => SecureRandom.uuid, "sender" => "central",
      "timestamp" => VALID_UNTIL.iso8601, "reason" => reason, "code" => code,
      "data" => { "target" => target, "message" => "rechazado" }.merge(extra)
    }
  end
end
