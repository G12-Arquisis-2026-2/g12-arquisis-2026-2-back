require 'minitest/autorun'
require_relative '../lib/rate_limiter'

# correr desde /connector: ruby test/rate_limiter_test.rb
class RateLimiterTest < Minitest::Test
  def setup
    @now = 0.0
    @limiter = RateLimiter.new(limit: 3, window: 60, clock: -> { @now })
  end

  def test_allows_up_to_the_limit_inside_the_window
    assert_equal [true, true, true, false], Array.new(4) { @limiter.take }
  end

  def test_window_is_sliding_not_fixed
    @limiter.take
    @now = 30
    2.times { @limiter.take }

    @now = 59.9
    refute @limiter.take
    @now = 60
    assert @limiter.take # salio el primero (t=0), los de t=30 siguen contando
    refute @limiter.take
    @now = 90
    assert @limiter.take
  end

  def test_a_refused_attempt_does_not_use_the_quota
    3.times { @limiter.take }
    5.times { @limiter.take }
    @now = 60

    assert_equal [true, true, true, false], Array.new(4) { @limiter.take }
  end
end
