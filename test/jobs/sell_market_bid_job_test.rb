require "test_helper"

class SellMarketBidJobTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  class SuccessfulWallet
    attr_reader :proposed

    def propose_swap(**attributes)
      @proposed = attributes
      WalletClient::Result.new(success?: true, status: 202, body: "{}", retry_required?: false)
    end
  end

  setup do
    @old_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    @cycle = Cycle.create!(
      cycle_id: "cycle-sell",
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
      cycle_id: @cycle.cycle_id,
      offer_id: "TK3-cycle-sell",
      city_id: "TK3",
      quantity: 100,
      remaining: 100,
      reserved_quantity: 0,
      price_per_energy: 20,
      active: true
    )
  end

  teardown { ENV["CITY_ID"] = @old_city }

  test "reserves capacity before proposing a wallet swap and never handles the bid twice" do
    bid = incoming_bid(quantity: 40)
    wallet = SuccessfulWallet.new

    with_singleton_stub(WalletClient, :new, wallet) do
      SellMarketBidJob.perform_now(bid.bid_idpk)
      SellMarketBidJob.perform_now(bid.bid_idpk)
    end

    bid.reload
    assert_equal "proposing", bid.status
    assert_equal 40, @offer.reload.reserved_quantity
    assert_equal 800.to_d, wallet.proposed[:take][:amount]
    assert_kind_of Numeric, wallet.proposed[:take][:amount]
    assert_equal bid.proposal_idpk, wallet.proposed[:idempotency_key]
    assert_equal 60, OutboxMessage.find_by!(message_type: "offer-updated").payload.dig("data", "remaining")
  end

  test "rejects a stale bid when it exceeds the remaining offer quantity" do
    @offer.update!(reserved_quantity: 70)
    bid = incoming_bid(quantity: 40)

    SellMarketBidJob.perform_now(bid.bid_idpk)

    assert_equal "rejected", bid.reload.status
    rejection = OutboxMessage.find_by!(message_type: "bid-rejected").payload
    assert_equal "QUANTITY_UNAVAILABLE", rejection["reason"]
    assert_equal 30, rejection.dig("data", "available")
    assert_equal 70, @offer.reload.reserved_quantity
  end

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

  def incoming_bid(quantity:)
    payload = {
      "idpk" => SecureRandom.uuid,
      "msgId" => SecureRandom.uuid,
      "type" => "bid",
      "cityId" => "COR",
      "cycleId" => @cycle.cycle_id,
      "data" => { "offerId" => @offer.offer_id, "quantity" => quantity }
    }
    MarketBid.create!(
      cycle_id: @cycle.cycle_id,
      offer_id: @offer.offer_id,
      bid_idpk: payload["idpk"],
      bid_msg_id: payload["msgId"],
      side: "sell",
      buyer_city: "COR",
      seller_city: "TK3",
      quantity: quantity,
      status: "pending",
      raw_payload: payload
    )
  end
end
