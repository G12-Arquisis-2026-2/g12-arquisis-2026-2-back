require "test_helper"

class MarketSwapEventServiceTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @old_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @cycle = Cycle.create!(
      cycle_id: "cycle-swap",
      generation_capacity: 1_000,
      consumption: 800,
      generation_cost: 10,
      sellable: 200,
      buyback_price: 10.5,
      imbalance_price: 100,
      min_bid: 10,
      last_bid_at: 5.minutes.from_now,
      closes_at: 6.minutes.from_now,
      valid_until: 10.minutes.from_now
    )
    @offer = MarketOffer.create!(
      cycle_id: @cycle.cycle_id, offer_id: "TK3-cycle-swap", city_id: "TK3",
      quantity: 100, remaining: 100, reserved_quantity: 40, price_per_energy: 20, active: true
    )
    @proposal_idpk = SecureRandom.uuid
    @bid = MarketBid.create!(
      cycle_id: @cycle.cycle_id,
      offer_id: @offer.offer_id,
      bid_idpk: SecureRandom.uuid,
      bid_msg_id: SecureRandom.uuid,
      side: "sell",
      buyer_city: "COR",
      seller_city: "TK3",
      quantity: 40,
      price_per_energy: 20,
      amount: 800,
      status: "proposing",
      proposal_idpk: @proposal_idpk,
      raw_payload: {}
    )
    SwapIntention.create!(idpk: @proposal_idpk, give_amount: 40, take_amount: 800, status: :pending)
  end

  teardown { ENV["CITY_ID"] = @old_city }

  private

  def with_singleton_stub(owner, name, replacement)
    singleton = owner.singleton_class
    backup = :"original_#{name}_#{object_id}"
    singleton.alias_method(backup, name)
    singleton.define_method(name) { |*| replacement }
    yield
  ensure
    singleton.alias_method(name, backup)
    singleton.remove_method(backup)
  end

  public

  test "forwards a proposed swap to the buyer only after token claims match the bid" do
    token = "signed-swap-token"
    claims = {
      "sub" => "swap-1",
      "proposer" => "TK3",
      "give" => { "asset" => "KWH", "amount" => 40 },
      "take" => { "asset" => "CR", "amount" => 800 },
      "memo" => @offer.offer_id,
      "exp" => 1.minute.from_now.to_i
    }
    with_singleton_stub(WalletTokenValidator, :verify!, claims) do
      MarketSwapEventService.call(
        "type" => "swap-proposed",
        "data" => {
          "idpk" => @proposal_idpk,
          "swapId" => "swap-1",
          "expiresAt" => 1.minute.from_now.iso8601,
          "token" => token
        }
      )
    end

    accepted = OutboxMessage.find_by!(message_type: "bid-accepted")
    assert_equal "city.COR", accepted.routing_key
    assert_equal @bid.bid_msg_id, accepted.payload.dig("data", "target")
    assert_equal token, accepted.payload.dig("data", "swapToken")
    assert_equal "proposed", @bid.reload.status
  end

  test "logs and acknowledges a wallet proposal with claims that do not match the bid" do
    with_singleton_stub(WalletTokenValidator, :verify!, false) do
      assert MarketSwapEventService.call(
        "type" => "swap-proposed",
        "data" => {
          "idpk" => @proposal_idpk,
          "swapId" => "swap-1",
          "expiresAt" => 1.minute.from_now.iso8601,
          "token" => "invalid-token"
        }
      )
    end

    assert_equal "proposing", @bid.reload.status
  end

  test "settlement consumes seller inventory and releases its reservation" do
    @bid.update!(status: "proposed", swap_id: "swap-1")
    SwapIntention.find_by!(idpk: @proposal_idpk).update!(swap_id: "swap-1")

    MarketSwapEventService.call(
      "type" => "swap-settled",
      "data" => { "swapId" => "swap-1", "idpk" => SecureRandom.uuid }
    )

    assert_equal "settled", @bid.reload.status
    assert_equal 60, @offer.reload.remaining
    assert_equal 0, @offer.reserved_quantity
    assert_equal :settled, SwapIntention.find_by!(idpk: @proposal_idpk).status.to_sym
  end
end
