require 'minitest/autorun'
require 'aws-sdk-states'
require_relative '../lib/master_client'
require_relative '../lib/outbox_sender'

# correr desde /connector (necesita la gema aws-sdk-states): ruby test/saga_starter_test.rb
class SagaStarterTest < Minitest::Test
  SELLER_ARN = 'arn:aws:states:us-east-1:123456789012:stateMachine:saga-seller'.freeze
  BUYER_ARN = 'arn:aws:states:us-east-1:123456789012:stateMachine:saga-buyer'.freeze

  # como la API: lo marcado deja de estar pendiente
  class FakeMaster
    attr_reader :marks

    def initialize(rows)
      @rows = rows
      @marks = []
    end

    def pending_outbox
      @rows.reject { |row| @marks.any? { |mark| mark.first == row['id'] } }
    end

    def mark_outbox(id, status, reason = nil)
      @marks << [id, status, reason]
      MasterClient::Result.new(200, '{}')
    end
  end

  class FakePublisher
    attr_reader :published

    def initialize
      @published = []
    end

    def publish_confirmed(message, **)
      @published << message
      true
    end

    def channel_open?
      true
    end

    def closed_by_broker; end
  end

  def setup
    @logs = []
    @now = 0.0
    @client = Aws::States::Client.new(stub_responses: true, region: 'us-east-1', retry_limit: 0)
    @client.stub_responses(:start_execution, execution_arn: "#{SELLER_ARN.sub('stateMachine', 'execution')}:x",
                                             start_date: Time.now)
  end

  def saga_row(id, role: 'seller', name: "idpk-#{id}", input: { 'bidIdpk' => "idpk-#{id}", 'quantity' => 40 })
    { 'id' => id, 'exchange' => 'step_functions', 'routing_key' => role,
      'payload' => { 'msgId' => "msg-#{id}", 'idpk' => name, 'type' => 'saga-start', 'timestamp' => '2026-11-26T22:00:00Z',
                     'cityId' => 'TK3', 'data' => { 'role' => role, 'name' => name, 'input' => input } } }
  end

  def central_row(id)
    { 'id' => id, 'exchange' => nil, 'routing_key' => nil,
      'payload' => { 'msgId' => "msg-#{id}", 'idpk' => "idpk-#{id}", 'type' => 'request', 'timestamp' => '2026-11-26T22:00:00Z',
                     'cityId' => 'TK3', 'data' => {} } }
  end

  def run_with(rows, enabled: true, publisher_enabled: true, arns: { 'seller' => SELLER_ARN, 'buyer' => BUYER_ARN },
               market_limiter: RateLimiter.new(limit: 50, window: 60))
    @master ||= FakeMaster.new(rows)
    @publisher ||= FakePublisher.new
    @starter ||= SagaStarter.new(client: @client, arns: arns, log: ->(text) { @logs << text }, enabled: enabled,
                                 clock: -> { @now })
    OutboxSender.new(master: @master, publisher: @publisher, city_id: 'TK3', log: ->(text) { @logs << text },
                     enabled: publisher_enabled, limiter: market_limiter, sagas: @starter).run_once
  end

  def stub_error(code)
    @client.stub_responses(:start_execution, code)
  end

  def calls
    @client.api_requests.map { |request| request[:params] }
  end

  def test_a_started_execution_is_marked_sent_with_the_idpk_as_name_and_the_input_as_json
    run_with([saga_row(1)])

    assert_equal [[1, 'sent', nil]], @master.marks
    assert_equal [{ state_machine_arn: SELLER_ARN, name: 'idpk-1', input: '{"bidIdpk":"idpk-1","quantity":40}' }], calls
    assert(@logs.any? { |line| line.start_with?('Saga seller idpk-1 iniciada') })
  end

  def test_the_buyer_row_uses_the_buyer_machine
    run_with([saga_row(1, role: 'buyer')])

    assert_equal BUYER_ARN, calls.first[:state_machine_arn]
  end

  def test_execution_already_exists_is_the_same_saga_and_is_marked_sent
    stub_error('ExecutionAlreadyExists')
    run_with([saga_row(1)])

    assert_equal [[1, 'sent', nil]], @master.marks
    assert(@logs.any? { |line| line.include?('ya existía (ExecutionAlreadyExists)') })
  end

  def test_throttling_leaves_it_pending_and_waits_30_s_before_calling_aws_again
    stub_error('ThrottlingException')
    run_with([saga_row(1), saga_row(2)])

    assert_empty @master.marks
    assert_equal 1, calls.size, 'tras el throttling no se prueba la siguiente en la misma vuelta'

    @now += 10
    run_with(nil)
    assert_equal 1, calls.size

    @client.stub_responses(:start_execution, execution_arn: 'arn:x', start_date: Time.now)
    @now += 25
    run_with(nil)
    assert_equal [[1, 'sent', nil], [2, 'sent', nil]], @master.marks
  end

  def test_a_network_error_leaves_it_pending
    @client.stub_responses(:start_execution, Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new))
    run_with([saga_row(1)])

    assert_empty @master.marks
    assert(@logs.any? { |line| line.include?('Seahorse::Client::NetworkingError') && line.include?('30 s') })
  end

  def test_definitive_errors_leave_it_failed_with_the_reason
    %w[AccessDeniedException StateMachineDoesNotExist InvalidName InvalidExecutionInput].each_with_index do |code, i|
      @master = @starter = nil
      stub_error(code)
      run_with([saga_row(i)])

      assert_equal [[i, 'failed', "Step Functions respondió #{code}"]], @master.marks
      assert(@logs.any? { |line| line.include?("#{code}, queda fallida") })
    end
  end

  def test_with_the_flag_off_nothing_is_executed_and_it_is_logged_once
    3.times { run_with([saga_row(1), saga_row(2)], enabled: false) }

    assert_empty calls
    assert_empty @master.marks
    assert_equal 2, @logs.grep(/SAGA_START_ENABLED apagado/).size
  end

  def test_the_default_sender_keeps_saga_rows_pending
    master = FakeMaster.new([saga_row(1)])
    OutboxSender.new(master: master, publisher: FakePublisher.new, city_id: 'TK3', log: ->(_) {}).run_once

    assert_empty master.marks
  end

  def test_a_waiting_saga_does_not_hold_the_messages_behind_it
    run_with([saga_row(1), central_row(2)], enabled: false)

    assert_equal [[2, 'sent', nil]], @master.marks
  end

  def test_sagas_do_not_use_the_market_quota_nor_depend_on_enable_publisher
    run_with([saga_row(1), saga_row(2)], publisher_enabled: false, market_limiter: RateLimiter.new(limit: 0, window: 60))

    assert_equal [[1, 'sent', nil], [2, 'sent', nil]], @master.marks
    assert_empty @publisher.published
  end

  def test_its_own_limit_of_60_per_minute
    run_with((1..65).map { |i| saga_row(i) })

    assert_equal 60, calls.size
    assert_equal 60, @master.marks.size
    assert(@logs.any? { |line| line.start_with?('Cupo de 60 sagas por minuto agotado') })
  end

  def test_a_missing_arn_keeps_it_pending
    run_with([saga_row(1)], arns: { 'seller' => nil, 'buyer' => BUYER_ARN })

    assert_empty calls
    assert_empty @master.marks
    assert(@logs.any? { |line| line.include?('Falta el ARN de la máquina seller') })
  end

  def test_rows_aws_would_reject_fail_without_calling_aws
    rows = [saga_row(1, name: ''), saga_row(2, name: 'a' * 81), saga_row(3, role: 'admin'), saga_row(4, input: 'texto'),
            saga_row(5).tap { |row| row['routing_key'] = 'buyer' }]
    run_with(rows)

    assert_empty calls
    assert_equal [1, 2, 3, 4, 5], @master.marks.map(&:first)
    assert(@master.marks.all? { |mark| mark[1] == 'failed' })
  end
end
