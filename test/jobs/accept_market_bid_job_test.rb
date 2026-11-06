require "test_helper"

class AcceptMarketBidJobTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  include ActiveJob::TestHelper

  class SuccessfulWallet
    attr_reader :accepted

    def accept_swap(**attributes)
      @accepted = attributes
      WalletClient::Result.new(success?: true, status: 202, body: "{}", retry_required?: false)
    end
  end

  setup do
    @old_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @cycle = Cycle.create!(cycle_id: "cycle-buy", generation_capacity: 800, consumption: 900,
                           generation_cost: 10, valid_until: 10.minutes.from_now)
    @bid = MarketBid.create!(
      cycle_id: @cycle.cycle_id,
      offer_id: "HGW-cycle-buy",
      bid_idpk: SecureRandom.uuid,
      bid_msg_id: SecureRandom.uuid,
      side: "buy",
      buyer_city: "TK3",
      seller_city: "HGW",
      quantity: 50,
      price_per_energy: 20,
      amount: 1_000,
      status: "sent",
      raw_payload: {}
    )
  end

  teardown { ENV["CITY_ID"] = @old_city }

  test "verifies the seller token and accepts the swap with a persisted idempotency key" do
    claims = token_claims
    wallet = SuccessfulWallet.new

    with_singleton_stub(WalletTokenValidator, :verify!, claims) do
      with_singleton_stub(WalletClient, :new, wallet) do
        AcceptMarketBidJob.perform_now(@bid.bid_msg_id, accepted_message)
      end
    end

    @bid.reload
    assert_equal "accepting", @bid.status
    assert_equal "swap-buy", @bid.swap_id
    assert_equal @bid.accept_idpk, wallet.accepted[:idempotency_key]
    assert SwapIntention.exists?(idpk: @bid.accept_idpk, swap_id: "swap-buy")
  end

  test "does not accept an invalid token and resumes the market strategy" do
    with_singleton_stub(WalletTokenValidator, :verify!, false) do
      AcceptMarketBidJob.perform_now(@bid.bid_msg_id, accepted_message)
    end

    assert_equal "rejected", @bid.reload.status
    assert_enqueued_with(job: MarketCycleJob, args: [@cycle.cycle_id])
  end

  test "does not accept a swap after the cycle closes" do
    @cycle.update!(market_closed_at: Time.current)
    wallet = SuccessfulWallet.new

    with_singleton_stub(WalletTokenValidator, :verify!, token_claims) do
      with_singleton_stub(WalletClient, :new, wallet) do
        AcceptMarketBidJob.perform_now(@bid.bid_msg_id, accepted_message)
      end
    end

    assert_equal "timed_out", @bid.reload.status
    assert_nil wallet.accepted
  end

  private

  def token_claims
    {
      "sub" => "swap-buy",
      "proposer" => "HGW",
      "give" => { "asset" => "KWH", "amount" => 50 },
      "take" => { "asset" => "CR", "amount" => 1_000 },
      "memo" => @bid.offer_id,
      "exp" => 1.minute.from_now.to_i
    }
  end

  def accepted_message
    {
      "data" => {
        "target" => @bid.bid_msg_id,
        "offerId" => @bid.offer_id,
        "quantity" => @bid.quantity,
        "pricePerEnergy" => @bid.price_per_energy,
        "amount" => @bid.amount,
        "swapId" => "swap-buy",
        "swapToken" => "signed-token",
        "expiresAt" => 1.minute.from_now.iso8601
      }
    }
  end

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
end
