require "test_helper"

class NegotiationServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  CYCLE_ID = "cycle-neg-svc".freeze

  # vendible = max(0, 1000 - 600) = 400; generationCost 10 → give a 10.5, take a 10
  setup do
    @cycle = Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 1000, consumption: 600, generation_cost: 10,
                           valid_until: 1.hour.from_now)
  end

  test "data.quantity of a give is the energy, not the amount" do
    payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 100)

    assert_equal 100.0, payload[:data][:quantity]
    assert_equal 10.5, payload[:data][:pricePerEnergy]
    assert_equal "give", payload[:data][:direction]
  end

  test "data.quantity of a take is the energy, not the amount" do
    payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "take", energy: 100)

    assert_equal 100.0, payload[:data][:quantity]
    assert_equal 10.0, payload[:data][:pricePerEnergy]
  end

  test "a give up to the sellable energy is accepted and above it is OVER_CAPACITY" do
    assert_nothing_raised { NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 400) }

    error = assert_raises(NegotiationService::OverCapacityError) do
      NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 401)
    end
    assert_match(/400/, error.message)
  end

  test "a take is not limited by own capacity" do
    payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "take", energy: 5000)

    assert_equal 5000.0, payload[:data][:quantity]
  end

  test "with spare 0 a give is rejected but a take is not" do
    @cycle.update!(consumption: 1200) # max(0, 1000 - 1200) = 0

    assert_equal 0, NegotiationService.available_capacity(1000, 1200)
    assert_raises(NegotiationService::OverCapacityError) do
      NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 1)
    end
    assert_nothing_raised { NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "take", energy: 50) }
  end

  test "energy already sold in the cycle is discounted from the sellable energy" do
    confirmed_give(CYCLE_ID, 300)

    assert_equal 300.0, NegotiationService.sold_energy(CYCLE_ID)
    assert_equal 100.0, NegotiationService.available_capacity(1000, 600, 300)
    assert_raises(NegotiationService::OverCapacityError) do
      NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 200)
    end
    assert_nothing_raised { NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 100) }
    # comprar sigue sin límite
    assert_nothing_raised { NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "take", energy: 5000) }
  end

  test "only gives of the same cycle count as sold" do
    confirmed_give("otro-ciclo", 400)
    Transaction.create!(idpk: SecureRandom.uuid, cycle_id: CYCLE_ID, operation_type: "take",
                        energy_change: 250, budget_change: -2500, raw_data: { "type" => "take" })

    assert_equal 0.0, NegotiationService.sold_energy(CYCLE_ID)
    assert_nothing_raised { NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 400) }
  end

  test "selling more than the remaining never goes negative" do
    assert_equal 0, NegotiationService.available_capacity(1000, 600, 500)
  end

  test "a retry keeps the idpk and gets a new msgId" do
    first = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 100)
    retry_payload = NegotiationService.build_proposal(cycle_id: CYCLE_ID, direction: "give", energy: 100,
                                                      existing_idpk: first[:idpk])

    assert_equal first[:idpk], retry_payload[:idpk]
    assert_not_equal first[:msgId], retry_payload[:msgId]
    assert_equal first[:data], retry_payload[:data]
  end

  test "an unknown cycle raises RecordNotFound" do
    assert_raises(ActiveRecord::RecordNotFound) do
      NegotiationService.build_proposal(cycle_id: "no-existe", direction: "give", energy: 1)
    end
  end

  private

  # Así queda en el ledger el give que confirma la central (LedgerProcessorService)
  def confirmed_give(cycle_id, energy)
    Transaction.create!(idpk: SecureRandom.uuid, cycle_id: cycle_id, operation_type: "give",
                        energy_change: -energy, budget_change: 0, raw_data: { "type" => "give" })
  end
end
