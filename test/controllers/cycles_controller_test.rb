require "test_helper"

# RF01. Los mensajes pasan por LedgerProcessorService, igual que cuando llegan por /events.
class CyclesControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  # Ventana de negociación del primer ciclo: [14:00, 14:20). La del siguiente cierra a las 16:20.
  VALID_UNTIL = Time.utc(2026, 10, 7, 14, 20)

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "a cycle with transfer, demand-statement, give and take" do
    create_cycle("cycle-1")
    Proposal.create!(idpk: "prop-1", cycle_id: "cycle-1", direction: "give", quantity: 120,
                     price_per_energy: 220.5, generation_cost: 210)
    ledger("transfer", "cycle-1", "quantity" => 500_000)
    ledger("demand-statement", "cycle-1", "balance" => { "quantity" => 100, "valuePerKwh" => 215 })
    ledger("take", "cycle-1", "target" => "p1", "energy" => 50, "pricePerEnergy" => 210)
    ledger("give", "cycle-1", { "target" => "p2", "energy" => 120, "pricePerEnergy" => 220.5 }, "give-1")
    ledger("transfer", "cycle-1", "becauseOf" => "give-1", "quantity" => 26_460) # 120 * 220.5

    get "/cycles/cycle-1"

    assert_response :ok
    cycle = response.parsed_body["cycle"]
    assert_equal "cycle-1", cycle["cycleId"]
    assert_equal VALID_UNTIL.iso8601, cycle["statusStatement"]["validUntil"]
    assert_number 1000, cycle["statusStatement"]["energy"]["generationCapacity"]
    # solo el transfer de fondos: el pago del give (26460) no se mezcla
    assert_number 500_000, cycle["fundsReceived"]
    assert_equal 1, cycle["demandStatements"].size
    assert_number 100, cycle["demandStatements"].first["quantity"]
    assert_number 215, cycle["demandStatements"].first["valuePerKwh"]
    assert_equal [["prop-1", "give", "paid"]],
                 cycle["voluntaryNegotiations"].map { |item| item.values_at("proposalId", "direction", "status") }
    assert_nil cycle["negotiationReport"]
    # budget: 500000 - 21500 (100*215) - 10500 (50*210) + 26460 (pago del give) = 494460
    # energía: 200 + 100 (demand) + 50 (take) - 120 (give) = 230
    assert_number 494_460, cycle["finalBalances"]["budget"]
    assert_number 230, cycle["finalBalances"]["energy"]
  end

  test "a later cycle does not alter the balance of the previous one" do
    # los cycleId son opacos: el orden lo da validUntil, no el texto ni el orden de llegada
    create_cycle("cycle-a", valid_until: VALID_UNTIL + 2.hours, generation_capacity: 600, consumption: 900)
    create_cycle("cycle-b")
    ledger("transfer", "cycle-b", "quantity" => 5000)
    ledger("demand-statement", "cycle-b", "balance" => { "quantity" => 3, "valuePerKwh" => 225 })
    ledger("transfer", "cycle-a", "quantity" => 7000)
    ledger("take", "cycle-a", "target" => "p1", "energy" => 10, "pricePerEnergy" => 210)

    get "/cycles"

    assert_response :ok
    later, previous = response.parsed_body["cycles"]
    assert_equal %w[cycle-a cycle-b], [later["cycleId"], previous["cycleId"]]
    # 5000 - 675 (3*225) = 4325: el transfer y el take del ciclo siguiente no entran
    assert_number 4325, previous["finalBalances"]["budget"]
    assert_number 203, previous["finalBalances"]["energy"]
    assert_number 5000, previous["fundsReceived"]
    assert_equal "demand-statement", previous["lastOperation"]
    # el budget sí se traspasa al ciclo siguiente: 4325 + 7000 - 2100 (10*210) = 9225. La energía no
    assert_number 9225, later["finalBalances"]["budget"]
    assert_number(-290, later["finalBalances"]["energy"])
    assert_number 7000, later["fundsReceived"]
    assert_equal "take", later["lastOperation"]
  end

  test "a cycle without transactions" do
    create_cycle("cycle-1")

    get "/cycles/current"

    assert_response :ok
    cycle = response.parsed_body["cycle"]
    assert_equal "cycle-1", cycle["cycleId"]
    assert_number 0, cycle["fundsReceived"]
    assert_equal [], cycle["demandStatements"]
    assert_equal [], cycle["voluntaryNegotiations"]
    assert_nil cycle["negotiationReport"]
    assert_equal({ "missedAt" => nil, "tooEarly" => false, "notBefore" => nil }, cycle["reportTracking"])
    assert_number 0, cycle["finalBalances"]["budget"]
    assert_number 200, cycle["finalBalances"]["energy"]
    assert_equal "status-statement", cycle["lastOperation"]
  end

  test "a cycle without transactions keeps the budget carried over from the previous one" do
    create_cycle("cycle-1")
    create_cycle("cycle-2", valid_until: VALID_UNTIL + 2.hours)
    ledger("transfer", "cycle-1", "quantity" => 5000)

    get "/cycles/cycle-2"

    cycle = response.parsed_body["cycle"]
    assert_number 0, cycle["fundsReceived"]
    assert_number 5000, cycle["finalBalances"]["budget"]
    assert_number 200, cycle["finalBalances"]["energy"]
  end

  test "sentAt is when the report was published, even if the cycle is edited later" do
    travel_to(VALID_UNTIL - 20.minutes) { create_cycle("cycle-1") }
    report = enqueue_report("cycle-1")
    travel_to(VALID_UNTIL - 2.minutes) { report.mark_sent! }
    # un status-statement repetido toca el ciclo (updated_at) después del envío
    travel_to(VALID_UNTIL + 30.minutes) { Cycle.find_by!(cycle_id: "cycle-1").update!(generation_capacity: 1001) }

    get "/cycles/cycle-1"

    cycle = response.parsed_body["cycle"]
    assert_equal (VALID_UNTIL - 2.minutes).iso8601, cycle["negotiationReport"]["sentAt"]
    assert_number 0, cycle["negotiationReport"]["budgetBalance"]
    assert_number 200, cycle["negotiationReport"]["energyBalance"]
    assert_equal "negotiation-report", cycle["lastOperation"]
  end

  test "sentAt is null while the report is still pending" do
    create_cycle("cycle-1")
    enqueue_report("cycle-1")

    get "/cycles/cycle-1"

    assert_response :ok
    cycle = response.parsed_body["cycle"]
    assert cycle["negotiationReport"].key?("sentAt")
    assert_nil cycle["negotiationReport"]["sentAt"]
    assert_number 200, cycle["negotiationReport"]["energyBalance"]
    assert_equal "status-statement", cycle["lastOperation"]
  end

  test "sentAt is null when the report failed, and the cycle shows it as missed" do
    create_cycle("cycle-1")
    report = enqueue_report("cycle-1")
    # la ventana cerró antes de que el connector lo publicara
    travel_to(VALID_UNTIL) { OutboxMessage.expire_late_reports! }
    travel_to(VALID_UNTIL + 1.minute) { CycleService.tick }

    get "/cycles/cycle-1"

    assert_response :ok
    assert_equal "failed", report.reload.status
    cycle = response.parsed_body["cycle"]
    assert_nil cycle["negotiationReport"]["sentAt"]
    assert_equal (VALID_UNTIL + 1.minute).iso8601, cycle["reportTracking"]["missedAt"]
    assert_equal "status-statement", cycle["lastOperation"]
  end

  test "sentAt is null when the connector reports the message as failed after publishing it" do
    create_cycle("cycle-1")
    report = enqueue_report("cycle-1")
    travel_to(VALID_UNTIL - 2.minutes) { report.mark_sent! }
    report.mark_failed!("unroutable")

    get "/cycles/cycle-1"

    assert_not_nil report.reload.sent_at
    assert_nil response.parsed_body["cycle"]["negotiationReport"]["sentAt"]
  end

  test "sentAt comes from the report in report_msg_id, not from another report of the cycle" do
    create_cycle("cycle-1")
    first = enqueue_report("cycle-1")
    travel_to(VALID_UNTIL - 170.seconds) { first.mark_sent! }
    # el ledger cambia en el periodo de cierre: sale una corrección, que es el reporte vigente
    ledger("transfer", "cycle-1", "quantity" => 5000)
    travel_to(VALID_UNTIL - 2.minutes) { CycleService.tick }
    correction = OutboxMessage.find_by!(msg_id: Cycle.find_by!(cycle_id: "cycle-1").report_msg_id)
    assert_not_equal first.msg_id, correction.msg_id

    get "/cycles/cycle-1"
    assert_nil response.parsed_body["cycle"]["negotiationReport"]["sentAt"]

    travel_to(VALID_UNTIL - 1.minute) { correction.mark_sent! }
    get "/cycles/cycle-1"

    cycle = response.parsed_body["cycle"]
    assert_equal (VALID_UNTIL - 1.minute).iso8601, cycle["negotiationReport"]["sentAt"]
    assert_number 5000, cycle["negotiationReport"]["budgetBalance"]
  end

  test "a cycle with the report missed" do
    create_cycle("cycle-1")
    ledger("transfer", "cycle-1", "quantity" => 5000)
    # la ventana cerró sin que se encolara ningún reporte
    missed_at = VALID_UNTIL + 1.minute
    travel_to(missed_at) { CycleService.tick }

    get "/cycles/cycle-1"

    assert_response :ok
    cycle = response.parsed_body["cycle"]
    assert_nil cycle["negotiationReport"]
    assert_equal({ "missedAt" => missed_at.iso8601, "tooEarly" => false, "notBefore" => nil }, cycle["reportTracking"])
    assert_number 5000, cycle["finalBalances"]["budget"]
    assert_equal "transfer", cycle["lastOperation"]
  end

  test "a report rejected with REPORT_TOO_EARLY shows since when it can be retried" do
    create_cycle("cycle-1")
    travel_to(VALID_UNTIL - 5.minutes) { CycleService.tick }
    opens_at = VALID_UNTIL - 4.minutes
    ErrorProcessorService.call(
      "type" => "error", "idpk" => SecureRandom.uuid, "reason" => "REPORT_TOO_EARLY", "code" => 425,
      "data" => { "target" => Cycle.find_by!(cycle_id: "cycle-1").report_msg_id, "opensAt" => opens_at.iso8601 }
    )

    get "/cycles/cycle-1"

    assert_equal({ "missedAt" => nil, "tooEarly" => true, "notBefore" => opens_at.iso8601 },
                 response.parsed_body["cycle"]["reportTracking"])

    # al reenviarlo deja de estar rechazado
    travel_to(opens_at) { CycleService.tick }
    get "/cycles/cycle-1"

    assert_equal({ "missedAt" => nil, "tooEarly" => false, "notBefore" => nil },
                 response.parsed_body["cycle"]["reportTracking"])
  end

  test "an unknown cycle responds 404 and no cycles responds 404 for current" do
    get "/cycles/cycle-404"
    assert_response :not_found

    get "/cycles/current"
    assert_response :not_found
  end

  private

  def create_cycle(cycle_id, valid_until: VALID_UNTIL, generation_capacity: 1000, consumption: 800)
    Cycle.create!(cycle_id: cycle_id, valid_until: valid_until, generation_capacity: generation_capacity,
                  consumption: consumption, generation_cost: 210)
  end

  # El orquestador encola el reporte dentro del periodo de cierre; devuelve el mensaje del outbox.
  def enqueue_report(cycle_id)
    travel_to(VALID_UNTIL - 3.minutes) { CycleService.tick }
    OutboxMessage.find_by!(msg_id: Cycle.find_by!(cycle_id: cycle_id).report_msg_id)
  end

  def ledger(type, cycle_id, data, msg_id = SecureRandom.uuid)
    LedgerProcessorService.call(
      "type" => type, "idpk" => SecureRandom.uuid, "msgId" => msg_id, "cycleId" => cycle_id, "data" => data
    )
  end

  # Los decimales salen como texto en el JSON ("494460.0"): se compara el valor, no el formato.
  def assert_number(expected, actual)
    assert_equal BigDecimal(expected.to_s), BigDecimal(actual.to_s)
  end
end
