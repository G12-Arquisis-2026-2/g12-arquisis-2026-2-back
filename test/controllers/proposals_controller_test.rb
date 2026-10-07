require "test_helper"

class ProposalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  self.fixture_table_names = []

  CYCLE_ID = "cycle-proposals-1".freeze

  setup do
    @previous_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    # vendible = max(0, 1000 - 600) = 400
    Cycle.create!(cycle_id: CYCLE_ID, generation_capacity: 1000, consumption: 600, generation_cost: 10,
                  valid_until: 1.hour.from_now)
  end

  teardown { ENV["CITY_ID"] = @previous_city }

  test "a give stores and publishes the energy as quantity" do
    post_proposal("give", 100)

    assert_response :created
    proposal = Proposal.sole
    assert_equal 100, proposal.quantity
    assert_equal 10.5, proposal.price_per_energy

    message = OutboxMessage.sole
    assert_equal "negotiation-proposal", message.message_type
    assert_equal proposal.idpk, message.idpk
    assert_equal({ "direction" => "give", "quantity" => 100.0, "pricePerEnergy" => 10.5 }, message.payload["data"])
    assert_equal CYCLE_ID, message.payload["cycleId"]
    assert_enqueued_with(job: NegotiationTimeoutJob, args: [proposal.idpk])
  end

  test "a take stores and publishes the energy as quantity" do
    post_proposal("take", 100)

    assert_response :created
    assert_equal 100, Proposal.sole.quantity
    assert_equal({ "direction" => "take", "quantity" => 100.0, "pricePerEnergy" => 10.0 },
                 OutboxMessage.sole.payload["data"])
  end

  test "a take above own capacity is accepted" do
    post_proposal("take", 5000)

    assert_response :created
    assert_equal 5000, Proposal.sole.quantity
  end

  test "a give above the sellable energy is 422 and nothing is stored" do
    post_proposal("give", 401)

    assert_response :unprocessable_entity
    assert_equal 0, Proposal.count
    assert_equal 0, OutboxMessage.count
  end

  test "a give above what remains after selling in the cycle is 422" do
    Transaction.create!(idpk: SecureRandom.uuid, cycle_id: CYCLE_ID, operation_type: "give",
                        energy_change: -300, budget_change: 0, raw_data: { "type" => "give" })

    post_proposal("give", 200)
    assert_response :unprocessable_entity

    post_proposal("give", 100)
    assert_response :created
  end

  test "if the publish fails the proposal is not stored" do
    with_publish_raising(ArgumentError.new("msgId e idpk deben ser distintos")) do
      post_proposal("give", 100)
    end

    assert_response :unprocessable_entity
    assert_equal 0, Proposal.count
    assert_equal 0, OutboxMessage.count
    assert_no_enqueued_jobs only: NegotiationTimeoutJob
  end

  private

  def with_publish_raising(error)
    original = RabbitMQPublisher.method(:publish)
    RabbitMQPublisher.define_singleton_method(:publish) { |*_args, **_fields| raise error }
    yield
  ensure
    RabbitMQPublisher.define_singleton_method(:publish, original)
  end

  def post_proposal(direction, energy)
    post "/proposals", params: { cycleId: CYCLE_ID, direction: direction, energy: energy }.to_json,
                       headers: { "CONTENT_TYPE" => "application/json" }
  end
end
