require 'minitest/autorun'
require_relative '../lib/broker_session'

# correr desde /connector: ruby test/broker_session_test.rb
class BrokerSessionTest < Minitest::Test
  # como Bunny::Session: open? y recovering_from_network_failure?
  class FakeConnection
    attr_accessor :open, :recovering, :close_delay
    attr_reader :closed

    def initialize
      @open = true
      @recovering = false
    end

    def open?
      @open
    end

    def recovering_from_network_failure?
      @recovering
    end

    def close
      sleep close_delay if close_delay
      @closed = true
    end
  end

  Channel = Struct.new(:open) do
    def open?
      open
    end
  end

  def build(market: Channel.new(true))
    @connection = FakeConnection.new
    @market_calls = 0
    BrokerSession.new(@connection,
                      subscribe_city: ->(_) { Channel.new(true) },
                      subscribe_market: lambda { |_|
                        @market_calls += 1
                        market
                      })
  end

  def test_subscribes_both_queues_on_the_connection
    session = build

    assert session.city_open?
    assert session.market?
    assert_equal 1, @market_calls
  end

  def test_works_without_the_market_queue_and_can_retry_it
    session = build(market: nil)
    refute session.market?
    refute session.retry_market
    assert_equal 2, @market_calls
  end

  def test_abandoned_only_when_closed_and_bunny_is_not_recovering
    session = build
    refute session.abandoned?

    @connection.open = false
    @connection.recovering = true
    refute session.abandoned?

    @connection.recovering = false
    assert session.abandoned?
  end

  def test_close_does_not_hang_nor_raise
    session = build
    @connection.close_delay = 30
    stub_timeout(0.05) { session.close }

    refute @connection.closed
  end

  private

  def stub_timeout(seconds)
    original = BrokerSession::CLOSE_TIMEOUT
    BrokerSession.send(:remove_const, :CLOSE_TIMEOUT)
    BrokerSession.const_set(:CLOSE_TIMEOUT, seconds)
    yield
  ensure
    BrokerSession.send(:remove_const, :CLOSE_TIMEOUT)
    BrokerSession.const_set(:CLOSE_TIMEOUT, original)
  end
end
