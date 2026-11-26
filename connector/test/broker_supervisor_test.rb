require 'minitest/autorun'
require_relative '../lib/broker_supervisor'

# correr desde /connector: ruby test/broker_supervisor_test.rb
class BrokerSupervisorTest < Minitest::Test
  # lo que el supervisor necesita de una BrokerSession
  class FakeSession
    attr_accessor :open, :recovering, :city_open, :market, :market_available
    attr_reader :closed, :market_attempts

    def initialize(market: true)
      @open = true
      @recovering = false
      @city_open = true
      @market = market
      @market_available = market
      @market_attempts = 0
      @closed = false
    end

    def open?
      @open
    end

    def abandoned?
      !@open && !@recovering
    end

    def city_open?
      @city_open
    end

    def market?
      @market
    end

    def retry_market
      @market_attempts += 1
      @market = @market_available
    end

    def close
      @closed = true
      @open = false
    end
  end

  def setup
    @logs = []
    @alive = 0
    @exits = []
    @now = 0.0
    @broker_up = true
    @opened = []
    @new_sessions = []
    @next_session = -> { FakeSession.new }
    @supervisor = BrokerSupervisor.new(
      open_session: lambda {
        raise IOError, 'sin broker' unless @broker_up

        @next_session.call.tap { |session| @opened << session }
      },
      on_new_session: ->(session) { @new_sessions << session },
      log: ->(text) { @logs << text },
      alive: -> { @alive += 1 },
      exit_process: ->(code) { @exits << code },
      clock: -> { @now }
    )
  end

  # una vuelta del hilo principal: tick y 5 s de espera
  def run_for(seconds)
    (seconds / 5).times do
      @supervisor.tick
      @now += 5
    end
  end

  def test_five_minutes_without_broker_from_the_start_do_not_end_the_process
    @broker_up = false
    run_for(300)

    assert_empty @exits
    assert_equal 0, @alive
    refute @supervisor.connected?
    assert(@logs.any? { |line| line.include?('No se pudo conectar al broker (IOError)') })
    refute(@logs.any? { |line| line.include?('sin broker') }, 'no se imprime e.message')
  end

  def test_five_minutes_after_losing_the_broker_do_not_end_the_process_nor_touch_the_healthcheck
    run_for(10)
    alive_before = @alive
    session = @opened.first
    session.open = false
    session.recovering = true # bunny sigue intentando solo
    run_for(300)

    assert_empty @exits
    assert_equal alive_before, @alive
    assert_equal 1, @opened.size, 'mientras bunny reintenta no se abre otra conexion'
  end

  def test_offline_logs_say_how_long_and_are_not_written_every_tick
    run_for(5)
    @opened.first.open = false
    @opened.first.recovering = true
    run_for(300)

    waiting = @logs.grep(/Sin conexión con el broker hace \d+ s, reintentando/)
    assert_equal 4, waiting.size
    assert_includes waiting.first, 'hace 60 s'
  end

  def test_when_the_broker_comes_back_it_logs_the_seconds_offline_and_touches_the_healthcheck
    run_for(5)
    session = @opened.first
    session.open = false
    session.recovering = true
    run_for(240)
    alive_before = @alive
    session.open = true
    session.recovering = false
    run_for(5)

    assert(@logs.any? { |line| line == 'Conexión con el broker recuperada tras 240 s.' })
    assert_equal alive_before + 1, @alive
  end

  def test_if_bunny_gives_up_it_closes_that_connection_and_opens_a_new_one_with_both_queues
    run_for(5)
    old = @opened.first
    old.open = false
    old.recovering = false # bunny se rindio
    @broker_up = false
    run_for(300)
    @broker_up = true
    run_for(5)

    assert old.closed
    assert_equal 2, @opened.size
    assert @supervisor.connected?
    assert_same @opened.last, @supervisor.session
    assert @supervisor.session.city_open?
    assert @supervisor.session.market?
    assert_equal @opened, @new_sessions, 'cada sesion nueva avisa (el outbox reabre su canal)'
    assert_empty @exits
    assert(@logs.any? { |line| line.include?('Bunny dejó de reintentar') })
    assert(@logs.any? { |line| line.start_with?('Conexión con el broker recuperada tras') })
  end

  def test_a_failure_bunny_is_about_to_recover_is_not_treated_as_abandoned
    run_for(5)
    session = @opened.first
    session.open = false
    session.recovering = false
    @supervisor.tick
    session.recovering = true
    run_for(30)

    refute session.closed
    assert_equal 1, @opened.size
  end

  def test_a_missing_market_queue_is_retried_every_30_s_without_affecting_the_city_queue
    @next_session = -> { FakeSession.new(market: false) }
    run_for(5)
    session = @opened.first
    run_for(90)

    assert_equal 3, session.market_attempts
    assert_operator @alive, :>=, 18
    session.market_available = true
    run_for(30)

    assert session.market?
    assert(@logs.any? { |line| line == 'Suscrito a la cola del mercado.' })
    assert_empty @exits
  end

  def test_the_missing_market_queue_is_not_logged_every_attempt
    @next_session = -> { FakeSession.new(market: false) }
    run_for(600)

    assert_equal 2, @logs.grep(/Sin la cola del mercado/).size
  end

  def test_a_city_channel_closed_with_the_connection_open_still_ends_the_process
    run_for(5)
    @opened.first.city_open = false
    @supervisor.tick
    assert_empty @exits

    @supervisor.tick
    assert_equal [1], @exits
  end

  def test_a_city_channel_that_comes_back_does_not_end_the_process
    run_for(5)
    @opened.first.city_open = false
    @supervisor.tick
    @opened.first.city_open = true
    run_for(20)

    assert_empty @exits
  end
end
