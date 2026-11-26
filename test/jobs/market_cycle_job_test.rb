require "test_helper"

class MarketCycleJobTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  class WalletWithBalance
    def get_balance
      { "balances" => { "KWH" => { "available" => 200, "held" => 0 } } }
    end
  end

  # con la forma que lee el job (assets.KWH.available)
  class WalletWithAssets
    def get_balance
      { "assets" => { "KWH" => { "available" => 200 } } }
    end
  end

  setup do
    @old_city = ENV["CITY_ID"]
    ENV["CITY_ID"] = "TK3"
    strategy = MarketStrategy.create!(
      sell_price_multiplier: 1.1,
      max_buy_effective_price_ratio: 1,
      span_seconds: 60,
      active: true
    )
    @cycle = Cycle.create!(
      cycle_id: "cycle-auto",
      generation_capacity: 1_000,
      consumption: 800,
      generation_cost: 200,
      sellable: 200,
      buyback_price: 210,
      imbalance_price: 600,
      min_bid: 10,
      market_opens_at: 1.minute.ago,
      last_offer_at: 5.minutes.from_now,
      last_bid_at: 6.minutes.from_now,
      closes_at: 7.minutes.from_now,
      valid_until: 10.minutes.from_now,
      market_strategy: strategy
    )
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

  test "automatically publishes the sellable quantity through the market outbox" do
    with_singleton_stub(WalletClient, :new, WalletWithBalance.new) do
      MarketCycleJob.perform_now(@cycle.cycle_id)
    end

    offer = OutboxMessage.find_by!(message_type: "offer")
    assert_equal "market", offer.exchange
    assert_equal "market.offer.TK3", offer.routing_key
    assert_equal 200, offer.payload.dig("data", "quantity")
    assert_equal 231, offer.payload.dig("data", "pricePerEnergy")
    assert_equal 1, MarketOffer.where(cycle_id: @cycle.cycle_id).count
  end

  test "automatically bids on the cheapest offer by effective transport price" do
    @cycle.update!(
      generation_capacity: 800,
      consumption: 1_000,
      sellable: 0
    )
    MarketOffer.create!(
      cycle_id: @cycle.cycle_id, offer_id: "HGW-offer", city_id: "HGW",
      quantity: 200, remaining: 200, price_per_energy: 220, active: true
    )
    DistanceTable.create!(destination_code: "HGW", distance: 100, transport_cost: 0.1, enabled: true)

    MarketCycleJob.perform_now(@cycle.cycle_id)

    bid_message = OutboxMessage.find_by!(message_type: "bid")
    assert_equal "city.HGW", bid_message.routing_key
    assert_equal 200, bid_message.payload.dig("data", "quantity")
    bid = MarketBid.find_by!(bid_msg_id: bid_message.msg_id)
    assert_equal 220.to_d, bid.price_per_energy
    assert_equal 44_000.to_d, bid.amount
  end
  test "if the offer message cannot be written, the offer is not saved either" do
    with_singleton_stub(WalletClient, :new, WalletWithAssets.new) do
      with_failing_publisher do
        assert_raises(RuntimeError) { MarketCycleJob.perform_now(@cycle.cycle_id) }
      end
    end

    assert_equal 0, MarketOffer.count
    assert_equal 0, OutboxMessage.count
  end

  test "if the offer-updated message cannot be written, the offer keeps its old remaining" do
    offer = MarketOffer.create!(cycle_id: @cycle.cycle_id, city_id: "TK3", offer_id: "TK3-#{@cycle.cycle_id}",
                                quantity: 150, remaining: 150, reserved_quantity: 0, price_per_energy: 231, active: true)

    with_singleton_stub(WalletClient, :new, WalletWithAssets.new) do
      with_failing_publisher do
        assert_raises(RuntimeError) { MarketCycleJob.perform_now(@cycle.cycle_id) }
      end
    end

    assert_equal 150, offer.reload.remaining
    assert_equal 0, OutboxMessage.count
  end

  test "the bid is saved before it is published, and neither stays if the message fails" do
    @cycle.update!(generation_capacity: 800, consumption: 1_000, sellable: 0)
    MarketOffer.create!(cycle_id: @cycle.cycle_id, offer_id: "HGW-offer", city_id: "HGW",
                        quantity: 200, remaining: 200, price_per_energy: 220, active: true)
    DistanceTable.create!(destination_code: "HGW", distance: 100, transport_cost: 0.1, enabled: true)
    bids_when_published = nil

    with_failing_publisher(-> { bids_when_published = MarketBid.count }) do
      assert_raises(RuntimeError) { MarketCycleJob.perform_now(@cycle.cycle_id) }
    end

    assert_equal 1, bids_when_published
    assert_equal 0, MarketBid.count
    assert_equal 0, OutboxMessage.count
  end

  private

  def with_failing_publisher(before_raise = -> {})
    singleton = RabbitMQPublisher.singleton_class
    singleton.alias_method(:original_publish_for_test, :publish)
    singleton.define_method(:publish) do |*|
      before_raise.call
      raise "no se pudo escribir el outbox"
    end
    yield
  ensure
    singleton.alias_method(:publish, :original_publish_for_test)
    singleton.remove_method(:original_publish_for_test)
  end
end
