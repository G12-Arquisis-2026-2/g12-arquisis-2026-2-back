require "test_helper"

# Los mensajes pasan por LedgerProcessorService, igual que cuando llegan por /events.
class CycleBalanceServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    # ciclo 1: produce 1000, consume 800 (sobran 200), generationCost 210
    @cycle1 = Cycle.create!(cycle_id: "cycle-1", generation_capacity: 1000, consumption: 800, generation_cost: 210)
    # ciclo 2: produce 600, consume 900 (faltan 300), generationCost 200
    @cycle2 = Cycle.create!(cycle_id: "cycle-2", generation_capacity: 600, consumption: 900, generation_cost: 200)
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "cycle 1: transfer, demand-statement, take and a paid give" do
    ledger("transfer", "cycle-1", "quantity" => 500_000)
    ledger("demand-statement", "cycle-1", "balance" => { "quantity" => 100, "valuePerKwh" => 215 })
    ledger("take", "cycle-1", "target" => "p1", "energy" => 50, "pricePerEnergy" => 210)
    ledger("give", "cycle-1", { "target" => "p2", "energy" => 120, "pricePerEnergy" => 220.5 }, "give-1")
    ledger("transfer", "cycle-1", "becauseOf" => "give-1", "quantity" => 26_460) # 120 * 220.5

    # energía: 200 + 100 (demand) + 50 (take) - 120 (give) = 230
    # budget: 500000 - 21500 (100*215) - 10500 (50*210) + 26460 (pago del give) = 494460
    assert_balances({ budget: 494_460, energy: 230 }, @cycle1)
  end

  test "the budget carries over to the next cycle, the penalty is not charged twice and energy does not" do
    ledger("transfer", "cycle-1", "quantity" => 500_000)
    ledger("take", "cycle-1", "target" => "p1", "energy" => 50, "pricePerEnergy" => 210)
    # ciclo 2: el transfer ya viene con la multa de 50000 descontada; penalty solo la declara
    ledger("transfer", "cycle-2", "quantity" => 450_000, "penalty" => 50_000)
    # demand-statement negativo: la central retira 40 kWh y nos paga 40*200
    ledger("demand-statement", "cycle-2", "balance" => { "quantity" => -40, "valuePerKwh" => 200 })

    # budget: 500000 - 10500 + 450000 + 8000 = 947500 (acumulado de ambos ciclos)
    # energía ciclo 2: (600 - 900) - 40 = -340. Los 50 kWh del take del ciclo 1 no pasan
    assert_balances({ budget: 947_500, energy: -340 }, @cycle2)
    assert_equal 250, CycleBalanceService.call(@cycle1)[:energy]
  end

  test "what happens in a later cycle does not change the budget of the previous one" do
    ledger("transfer", "cycle-1", "quantity" => 5000)
    ledger("demand-statement", "cycle-1", "balance" => { "quantity" => 3, "valuePerKwh" => 225 })
    ledger("transfer", "cycle-2", "quantity" => 7000)

    # ciclo 1: 5000 - 675 = 4325. El transfer del ciclo 2 solo cuenta desde el ciclo 2
    assert_equal 4325, CycleBalanceService.call(@cycle1)[:budget]
    assert_equal 11_325, CycleBalanceService.call(@cycle2)[:budget]
  end

  test "cycles are ordered by validUntil, not by cycleId or arrival" do
    @cycle1.update!(valid_until: Time.utc(2026, 10, 7, 16, 20))
    @cycle2.update!(valid_until: Time.utc(2026, 10, 7, 14, 20))
    ledger("transfer", "cycle-1", "quantity" => 5000)
    ledger("transfer", "cycle-2", "quantity" => 7000)

    assert_equal 12_000, CycleBalanceService.call(@cycle1)[:budget]
    assert_equal 7000, CycleBalanceService.call(@cycle2)[:budget]
  end

  test "a give without its payment transfer does not count" do
    ledger("give", "cycle-1", { "target" => "p2", "energy" => 120, "pricePerEnergy" => 220.5 }, "give-1")
    # un pago de otro give no sirve
    ledger("transfer", "cycle-1", "becauseOf" => "otro-give", "quantity" => 1000)

    assert_balances({ budget: 1000, energy: 200 }, @cycle1)
  end

  test "the budget can go negative" do
    ledger("transfer", "cycle-2", "quantity" => 1000)
    ledger("take", "cycle-2", "target" => "p1", "energy" => 300, "pricePerEnergy" => 200)

    # 1000 - 60000 = -59000; energía: -300 + 300 = 0
    assert_balances({ budget: -59_000, energy: 0 }, @cycle2)
  end

  test "the take total is rounded to 2 decimals after the unit price" do
    ledger("take", "cycle-1", "target" => "p1", "energy" => 1.5, "pricePerEnergy" => 220.53)

    # 1.5 * 220.53 = 330.795 -> 330.80
    assert_equal BigDecimal("-330.80"), CycleBalanceService.call(@cycle1)[:budget]
  end

  test "a repeated give or take (same idpk) moves the ledger once" do
    2.times { ledger("take", "cycle-1", { "target" => "p1", "energy" => 50, "pricePerEnergy" => 210 }, SecureRandom.uuid, "take-1") }

    assert_balances({ budget: -10_500, energy: 250 }, @cycle1)
    assert_equal 1, AuditLog.where(idpk: "take-1", event_type: "DUPLICATE").count
  end

  private

  def ledger(type, cycle_id, data, msg_id = SecureRandom.uuid, idpk = SecureRandom.uuid)
    LedgerProcessorService.call(
      "type" => type, "idpk" => idpk, "msgId" => msg_id, "cycleId" => cycle_id, "data" => data
    )
  end

  def assert_balances(expected, cycle)
    actual = CycleBalanceService.call(cycle)
    assert_equal expected[:budget], actual[:budget], "budgetBalance"
    assert_equal expected[:energy], actual[:energy], "energyBalance"
  end
end
