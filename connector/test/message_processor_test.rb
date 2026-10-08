require 'minitest/autorun'
require 'json'
require_relative '../lib/master_client'
require_relative '../lib/message_processor'

# correr desde /connector: ruby test/message_processor_test.rb
class MessageProcessorTest < Minitest::Test
  class FakeMaster
    attr_reader :delivered, :rejected
    attr_writer :status

    def initialize(calls, status: 201, body: '{}', rejected_status: 201)
      @calls = calls
      @status = status
      @body = body
      @rejected_status = rejected_status
      @delivered = []
      @rejected = []
    end

    def deliver(message)
      @calls << :deliver
      @delivered << message
      MasterClient::Result.new(@status, @body)
    end

    def report_rejected(kind:, raw:, reason:)
      @calls << :report_rejected
      @rejected << { kind: kind, raw: raw, reason: reason }
      MasterClient::Result.new(@rejected_status, '{}')
    end
  end

  class FakePublisher
    attr_reader :acks, :nacks

    def initialize(calls)
      @calls = calls
      @acks = []
      @nacks = []
    end

    def ack(message)
      @calls << :ack
      @acks << message
    end

    def nack(message, reason, code, detail)
      @calls << :nack
      @nacks << { message: message, reason: reason, code: code, detail: detail }
    end
  end

  def build(**master_options)
    @calls = []
    @logs = []
    @sleeps = []
    @master = FakeMaster.new(@calls, **master_options)
    @publisher = FakePublisher.new(@calls)
    MessageProcessor.new(master: @master, publisher: @publisher, log: ->(text) { @logs << text },
                         sleeper: ->(seconds) { @sleeps << seconds })
  end

  def valid_message(changes = {})
    {
      'msgId' => '11111111-1111-4111-8111-111111111111',
      'idpk' => '22222222-2222-4222-8222-222222222222',
      'type' => 'transfer',
      'timestamp' => '2026-10-06T14:00:00Z',
      'sender' => 'central',
      'cycleId' => 'cycle-9431',
      'data' => { 'quantity' => 508_145 }
    }.merge(changes)
  end

  def test_valid_message_is_saved_and_then_acked
    processor = build

    assert_equal :done, processor.process(JSON.generate(valid_message))
    assert_equal %i[deliver ack], @calls
    assert_equal valid_message, @master.delivered.first
    assert_equal valid_message['msgId'], @publisher.acks.first['msgId']
  end

  def test_master_down_means_no_reply_and_retry
    processor = build(status: nil, body: 'Errno::ECONNREFUSED')

    assert_equal :retry, processor.process(JSON.generate(valid_message))
    assert_equal %i[deliver], @calls
    assert_equal [MessageProcessor::WAIT_DELAY], @sleeps
  end

  def test_master_error_500_means_no_reply_and_retry
    processor = build(status: 500)

    assert_equal :retry, processor.process(JSON.generate(valid_message))
    assert_equal %i[deliver], @calls
  end

  def test_master_422_publishes_nack_with_master_reason
    processor = build(status: 422, body: '{"error":"cycleId desconocido"}')

    assert_equal :done, processor.process(JSON.generate(valid_message))
    assert_equal %i[deliver nack], @calls
    nack = @publisher.nacks.first
    assert_equal ['MALFORMED_MESSAGE', 422, 'cycleId desconocido'], nack.values_at(:reason, :code, :detail)
  end

  def test_malformed_message_is_nacked_reported_and_never_reaches_master
    processor = build
    message = valid_message
    message.delete('timestamp')

    assert_equal :done, processor.process(JSON.generate(message))
    assert_equal %i[nack report_rejected], @calls
    assert_empty @master.delivered
    assert_equal ['MALFORMED_MESSAGE', 422], @publisher.nacks.first.values_at(:reason, :code)
    assert_equal({ kind: 'nack', raw: message, reason: 'MALFORMED_MESSAGE' }, @master.rejected.first)
  end

  def test_text_that_is_not_json_is_discarded
    processor = build

    assert_equal :done, processor.process('esto no es JSON')
    assert_equal %i[report_rejected], @calls
    assert_equal 'discard', @master.rejected.first[:kind]
    assert_equal 'esto no es JSON', @master.rejected.first[:raw]
  end

  def test_unreadable_bytes_are_discarded_without_crashing
    processor = build

    assert_equal :done, processor.process("\xFF\xFE\x00\xC3".b)
    assert_equal %i[report_rejected], @calls
    assert JSON.generate(@master.rejected.first[:raw])
  end

  def test_ack_from_central_is_saved_but_not_answered
    processor = build
    ack = valid_message('type' => 'ack', 'data' => { 'target' => 'abc' })

    assert_equal :done, processor.process(JSON.generate(ack))
    assert_equal %i[deliver], @calls
  end

  def test_reply_from_central_is_not_nacked_even_if_master_says_422
    processor = build(status: 422)
    nack = valid_message('type' => 'nack')

    assert_equal :done, processor.process(JSON.generate(nack))
    assert_equal %i[deliver], @calls
  end

  def test_failed_report_is_logged_and_processing_continues
    processor = build(rejected_status: nil)

    assert_equal :done, processor.process('esto no es JSON')
    assert(@logs.any? { |line| line.include?('No se pudo avisar') })
  end

  def test_failure_publishing_the_ack_returns_retry
    processor = build
    @publisher.define_singleton_method(:ack) { |_message| raise 'canal cerrado' }

    assert_equal :retry, processor.process(JSON.generate(valid_message))
  end

  def test_json_with_invalid_byte_is_discarded_and_never_retried
    processor = build

    assert_equal :done, processor.process("{\"msgId\":\"a\xFF\"}".b)
    assert_equal %i[report_rejected], @calls
    assert_equal 'discard', @master.rejected.first[:kind]
    assert JSON.generate(@master.rejected.first[:raw])
  end

  def test_validator_exception_is_treated_as_discard
    processor = build
    original = MessageValidator.method(:check)
    MessageValidator.define_singleton_method(:check) { |_body| raise 'error del validador' }

    assert_equal :done, processor.process(JSON.generate(valid_message))
    assert_equal %i[report_rejected], @calls
    assert_equal 'discard', @master.rejected.first[:kind]
    assert(@logs.any? { |line| line.include?('el validador falló') })
  ensure
    MessageValidator.define_singleton_method(:check, original)
  end

  def test_message_without_msg_id_is_reported_as_the_original_text
    processor = build
    message = valid_message
    message.delete('msgId')
    body = JSON.generate(message)

    assert_equal :done, processor.process(body)
    assert_equal %i[report_rejected], @calls
    assert_equal({ kind: 'discard', raw: body, reason: 'el mensaje no trae msgId' }, @master.rejected.first)
  end

  def test_null_byte_is_replaced_before_reporting
    processor = build

    assert_equal :done, processor.process("nul\x00byte")
    assert_equal 'nul?byte', @master.rejected.first[:raw]
  end

  def test_nack_from_central_is_logged_with_reason_code_and_target
    processor = build
    nack = valid_message('type' => 'nack', 'reason' => 'MALFORMED_MESSAGE', 'code' => 422,
                         'data' => { 'target' => 'msg-rechazado', 'message' => 'x' })

    assert_equal :done, processor.process(JSON.generate(nack))
    assert_equal %i[deliver], @calls
    line = @logs.find { |text| text.include?('La central rechazó') }
    assert_includes line, 'MALFORMED_MESSAGE'
    assert_includes line, '422'
    assert_includes line, 'msg-rechazado'
    refute_includes line, 'RABBITMQ_USER'
  end

  def test_identity_mismatch_says_what_to_check
    processor = build
    nack = valid_message('type' => 'nack', 'reason' => 'IDENTITY_MISMATCH', 'code' => 403,
                         'data' => { 'target' => 'msg-rechazado' })

    assert_equal :done, processor.process(JSON.generate(nack))
    assert_equal %i[deliver], @calls
    assert(@logs.any? { |text| text.include?('Revisar RABBITMQ_USER y CITY_ID') })
  end

  def test_retries_with_growing_backoff_and_then_rejects
    processor = build(status: 500)
    body = JSON.generate(valid_message)

    3.times { assert_equal :retry, processor.process(body) }
    assert_equal [5, 15, 45], @sleeps
    assert_empty @publisher.nacks

    assert_equal :reject, processor.process(body)
    assert_equal [5, 15, 45], @sleeps
    assert_equal %i[deliver deliver deliver deliver report_rejected], @calls
    assert_equal({ kind: 'discard', raw: valid_message, reason: 'MAX_RETRIES_EXCEEDED' }, @master.rejected.first)
    assert_empty @publisher.acks + @publisher.nacks
  end

  def test_master_422_unknown_type_publishes_nack_with_code_400
    processor = build(status: 422, body: '{"error":"UNKNOWN_TYPE","detail":"type \"x\" is not supported"}')

    assert_equal :done, processor.process(JSON.generate(valid_message))
    nack = @publisher.nacks.first
    assert_equal ['UNKNOWN_TYPE', 400, 'type "x" is not supported'], nack.values_at(:reason, :code, :detail)
  end

  def test_master_422_malformed_publishes_nack_with_its_detail
    processor = build(status: 422, body: '{"error":"MALFORMED_MESSAGE","detail":"missing field data.quantity"}')

    assert_equal :done, processor.process(JSON.generate(valid_message))
    nack = @publisher.nacks.first
    assert_equal ['MALFORMED_MESSAGE', 422, 'missing field data.quantity'], nack.values_at(:reason, :code, :detail)
  end

  # el enunciado: no se hacen ACKs de ACKs ni NACKs de NACKs (tampoco de error), pase lo que pase
  def test_replies_from_central_never_get_an_answer
    same_ids = '11111111-1111-4111-8111-111111111111'
    cases = {
      'valida, API guarda' => [{}, 201],
      'valida, API 422' => [{}, 422],
      'sin idpk' => [{ 'idpk' => nil }, 201],
      'timestamp invalido' => [{ 'timestamp' => 'ayer' }, 201],
      'idpk igual a msgId' => [{ 'idpk' => same_ids }, 201],
      'sin data' => [{ 'data' => nil }, 201]
    }
    %w[ack nack error].each do |type|
      cases.each do |name, (changes, status)|
        processor = build(status: status)
        message = valid_message({ 'type' => type, 'data' => { 'target' => 'x' } }.merge(changes)).compact

        assert_equal :done, processor.process(JSON.generate(message)), "#{type} #{name}"
        assert_empty @publisher.acks + @publisher.nacks, "#{type} #{name}"
      end
    end
  end

  def test_invalid_reply_from_central_is_registered_as_central
    processor = build
    message = valid_message('type' => 'nack', 'timestamp' => 'ayer')

    assert_equal :done, processor.process(JSON.generate(message))
    assert_equal %i[report_rejected], @calls
    rejected = @master.rejected.first
    assert_equal 'central', rejected[:kind]
    assert_equal message, rejected[:raw]
    assert_includes rejected[:reason], 'timestamp'
  end

  def test_after_rejecting_the_same_msg_id_starts_counting_again
    processor = build(status: 500)
    body = JSON.generate(valid_message)

    4.times { processor.process(body) }
    assert_equal :retry, processor.process(body)
    assert_equal [5, 15, 45, 5], @sleeps
  end

  def test_success_after_a_retry_resets_the_counter
    processor = build(status: 500)
    body = JSON.generate(valid_message)
    processor.process(body)

    @master.status = 201
    assert_equal :done, processor.process(body)

    @master.status = 500
    assert_equal :retry, processor.process(body)
    assert_equal [5, 5], @sleeps
  end

  def test_retries_are_counted_per_msg_id
    processor = build(status: 500)
    first = JSON.generate(valid_message)
    second = JSON.generate(valid_message('msgId' => '33333333-3333-4333-8333-333333333333'))

    2.times { processor.process(first) }
    assert_equal :retry, processor.process(second)
    assert_equal [5, 15, 5], @sleeps
  end

  # API caida: sin respuesta o 502, 503, 504. se espera lo que haga falta
  def test_api_down_many_times_is_never_discarded
    [nil, 502, 503, 504].each do |status|
      processor = build(status: status, body: 'Errno::ECONNREFUSED')
      body = JSON.generate(valid_message)

      50.times { assert_equal :retry, processor.process(body), "status #{status.inspect}" }
      assert_equal [MessageProcessor::WAIT_DELAY] * 50, @sleeps
      assert_equal [:deliver] * 50, @calls
      assert_empty @master.rejected
      assert_empty @publisher.acks + @publisher.nacks

      @master.status = 201
      assert_equal :done, processor.process(body)
      assert_equal 1, @publisher.acks.size
    end
  end

  def test_api_down_does_not_count_as_an_attempt
    processor = build(status: 500)
    body = JSON.generate(valid_message)
    2.times { assert_equal :retry, processor.process(body) }

    @master.status = 503
    20.times { assert_equal :retry, processor.process(body) }

    # la cuenta sigue donde estaba: ni sube ni parte de cero
    @master.status = 500
    assert_equal :retry, processor.process(body)
    assert_equal :reject, processor.process(body)
    assert_equal [5, 15] + [MessageProcessor::WAIT_DELAY] * 20 + [45], @sleeps
  end

  def test_failure_publishing_the_ack_many_times_is_never_discarded
    processor = build
    original = @publisher.method(:ack)
    @publisher.define_singleton_method(:ack) { |_message| raise 'canal cerrado' }
    body = JSON.generate(valid_message)

    50.times { assert_equal :retry, processor.process(body) }
    assert_equal [MessageProcessor::WAIT_DELAY] * 50, @sleeps
    assert_empty @master.rejected

    @publisher.define_singleton_method(:ack, original)
    assert_equal :done, processor.process(body)
    assert_equal 1, @publisher.acks.size
  end

  def test_failure_publishing_the_nack_many_times_is_never_discarded
    message = valid_message
    message.delete('timestamp')
    # nack del validador y nack por el 422 de la API
    { JSON.generate(message) => 201, JSON.generate(valid_message) => 422 }.each do |body, status|
      processor = build(status: status)
      original = @publisher.method(:nack)
      @publisher.define_singleton_method(:nack) { |*_args| raise 'canal cerrado' }

      50.times { assert_equal :retry, processor.process(body) }
      assert_equal [MessageProcessor::WAIT_DELAY] * 50, @sleeps
      assert_empty @master.rejected

      @publisher.define_singleton_method(:nack, original)
      assert_equal :done, processor.process(body)
      assert_equal 1, @publisher.nacks.size
    end
  end

  def test_publish_failure_does_not_count_as_an_attempt
    processor = build(status: 500)
    body = JSON.generate(valid_message)
    3.times { assert_equal :retry, processor.process(body) }

    @master.status = 201
    @publisher.define_singleton_method(:ack) { |_message| raise 'canal cerrado' }
    20.times { assert_equal :retry, processor.process(body) }

    @master.status = 500
    assert_equal :reject, processor.process(body)
  end

  # un 5xx que no es 502, 503 ni 504 es la API fallando con ese mensaje: ahi si hay tope
  def test_other_5xx_repeated_is_discarded_after_the_limit
    [500, 501, 505].each do |status|
      processor = build(status: status)
      body = JSON.generate(valid_message)

      3.times { assert_equal :retry, processor.process(body), "status #{status}" }
      assert_equal :reject, processor.process(body), "status #{status}"
      assert_equal [5, 15, 45], @sleeps
      assert_equal 'MAX_RETRIES_EXCEEDED', @master.rejected.first[:reason]
      assert_empty @publisher.acks + @publisher.nacks
    end
  end

  def test_reply_from_central_that_keeps_failing_is_rejected_without_answering
    processor = build(status: 500)
    body = JSON.generate(valid_message('type' => 'ack', 'data' => { 'target' => 'abc' }))

    3.times { processor.process(body) }
    assert_equal :reject, processor.process(body)
    assert_empty @publisher.nacks
    assert_equal 'MAX_RETRIES_EXCEEDED', @master.rejected.first[:reason]
  end

  def test_give_and_take_are_saved_and_acked
    %w[give take].each do |type|
      processor = build
      message = valid_message('type' => type, 'data' => { 'target' => 'msg-propuesta', 'energy' => 300,
                                                          'pricePerEnergy' => 1.5 })

      assert_equal :done, processor.process(JSON.generate(message))
      assert_equal %i[deliver ack], @calls
      assert_empty @publisher.nacks
    end
  end

  def test_status_statement_without_valid_until_is_nacked_and_acked_in_the_queue
    processor = build
    data = { 'energy' => { 'generationCapacity' => 900, 'consumption' => 700, 'generationCost' => 12 } }
    message = valid_message('type' => 'status-statement', 'data' => data)

    assert_equal :done, processor.process(JSON.generate(message))
    assert_equal %i[nack report_rejected], @calls
    assert_empty @master.delivered
    nack = @publisher.nacks.first
    assert_equal ['MALFORMED_MESSAGE', 422, 'falta el campo data.validUntil'], nack.values_at(:reason, :code, :detail)
  end

  def test_error_from_central_is_logged_and_nothing_is_published
    processor = build
    error = valid_message('type' => 'error', 'reason' => 'CYCLE_EXPIRED', 'code' => 410,
                          'data' => { 'target' => 'msg-rechazado', 'message' => 'x' })

    assert_equal :done, processor.process(JSON.generate(error))
    assert_empty @publisher.acks + @publisher.nacks
    assert(@logs.any? { |text| text.include?('CYCLE_EXPIRED') && text.include?('410') })
  end
end
