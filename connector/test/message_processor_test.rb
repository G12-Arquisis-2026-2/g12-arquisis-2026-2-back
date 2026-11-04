require 'minitest/autorun'
require 'json'
require_relative '../lib/master_client'
require_relative '../lib/message_processor'
require_relative 'support/samples'

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

    def ack(message, to_city: nil)
      @calls << :ack
      @acks << message.merge('respondidoA' => to_city)
    end

    def nack(message, reason, code, detail, to_city: nil)
      @calls << :nack
      @nacks << { message: message, reason: reason, code: code, detail: detail, to_city: to_city }
    end
  end

  def build(queue: :city, **master_options)
    @calls = []
    @logs = []
    @sleeps = []
    @master = FakeMaster.new(@calls, **master_options)
    @publisher = FakePublisher.new(@calls)
    # en la cola del mercado no hay publisher: si se intentara responder, revienta
    processor = MessageProcessor.new(master: @master, publisher: queue == :market ? nil : @publisher, queue: queue,
                                     log: ->(text) { @logs << text }, sleeper: ->(seconds) { @sleeps << seconds })
    # por omision los mensajes de prueba llegan como los publica la central: con user_id "central"
    original = processor.method(:process)
    processor.define_singleton_method(:process) { |body, user_id = 'central'| original.call(body, user_id) }
    processor
  end

  # un transfer de la central, tomado de los ejemplos oficiales
  def valid_message(changes = {})
    Samples.message('transfer', changes)
  end

  TARGET = '0b1c2d3e-4f50-4a61-8b72-9c83d4e5f607'.freeze

  def test_valid_message_is_saved_and_then_acked
    processor = build

    assert_equal :done, processor.process(JSON.generate(valid_message))
    assert_equal %i[deliver ack], @calls
    assert_equal valid_message, @master.delivered.first
    assert_equal valid_message['msgId'], @publisher.acks.first['msgId']
    assert_nil @publisher.acks.first['respondidoA']
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
    ack = Samples.message('ack')

    assert_equal :done, processor.process(JSON.generate(ack))
    assert_equal %i[deliver], @calls
  end

  def test_reply_from_central_is_not_nacked_even_if_master_says_422
    processor = build(status: 422)
    nack = Samples.message('nack')

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
    nack = Samples.message('nack', 'reason' => 'MALFORMED_MESSAGE', 'code' => 422,
                                   'data' => { 'target' => TARGET, 'message' => 'x' })

    assert_equal :done, processor.process(JSON.generate(nack))
    assert_equal %i[deliver], @calls
    line = @logs.find { |text| text.include?('La central rechazó') }
    assert_includes line, 'MALFORMED_MESSAGE'
    assert_includes line, '422'
    assert_includes line, TARGET
    refute_includes line, 'RABBITMQ_USER'
  end

  def test_identity_mismatch_says_what_to_check
    processor = build
    nack = Samples.message('nack', 'reason' => 'IDENTITY_MISMATCH', 'code' => 403,
                                   'data' => { 'target' => TARGET, 'message' => 'x' })

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
    body = JSON.generate(Samples.message('ack'))

    3.times { processor.process(body) }
    assert_equal :reject, processor.process(body)
    assert_empty @publisher.nacks
    assert_equal 'MAX_RETRIES_EXCEEDED', @master.rejected.first[:reason]
  end

  def test_give_and_take_are_retired_and_never_reach_the_api
    %w[give take demand-statement].each do |type|
      processor = build

      assert_equal :done, processor.process(JSON.generate(valid_message('type' => type)))
      assert_equal %i[nack report_rejected], @calls
      assert_equal ['UNKNOWN_TYPE', 400], @publisher.nacks.first.values_at(:reason, :code)
    end
  end

  def test_status_statement_without_market_is_nacked_and_acked_in_the_queue
    processor = build
    message = Samples.message('status-statement')
    message['data'].delete('market')

    assert_equal :done, processor.process(JSON.generate(message))
    assert_equal %i[nack report_rejected], @calls
    assert_empty @master.delivered
    nack = @publisher.nacks.first
    assert_equal ['MALFORMED_MESSAGE', 422, 'falta el campo data.market'], nack.values_at(:reason, :code, :detail)
  end

  # --- protocolo v3: otras ciudades ---

  # el bid oficial, pero enviado por HGW
  def bid(changes = {})
    Samples.message('bid', 'cityId' => 'HGW').merge(changes)
  end

  def test_bid_from_another_city_is_saved_and_acked_to_that_city
    processor = build

    assert_equal :done, processor.process(JSON.generate(bid), 'city.HGW')
    assert_equal %i[deliver ack], @calls
    assert_equal 'HGW', @publisher.acks.first['respondidoA']
  end

  def test_bid_with_foreign_user_id_gets_identity_mismatch_sent_to_the_real_sender
    processor = build

    assert_equal :done, processor.process(JSON.generate(bid), 'city.XXX')
    assert_equal %i[nack report_rejected], @calls
    assert_empty @master.delivered
    nack = @publisher.nacks.first
    assert_equal ['IDENTITY_MISMATCH', 403, 'XXX'], nack.values_at(:reason, :code, :to_city)
    assert(@logs.any? { |line| line.include?('responde a la ciudad XXX') })
  end

  # README v3.0.2: lo que dice venir de la central sin user_id "central" no lo publico ella
  def test_central_message_without_central_user_id_is_discarded_and_reported
    [nil, 'city.XXX'].each do |user_id|
      [valid_message, Samples.message('swap-settled'), Samples.message('ack')].each do |message|
        processor = build

        assert_equal :done, processor.process(JSON.generate(message), user_id)
        assert_equal %i[report_rejected], @calls
        assert_equal 'discard', @master.rejected.first[:kind]
        assert_empty @publisher.acks + @publisher.nacks
      end
    end
  end

  # sin user_id: IDENTITY_MISMATCH a la ciudad que dice ser, la unica a la que se puede responder
  def test_bid_without_user_id_gets_identity_mismatch_sent_to_its_city_id
    processor = build

    assert_equal :done, processor.process(JSON.generate(bid), nil)
    assert_equal ['IDENTITY_MISMATCH', 403, 'HGW'], @publisher.nacks.first.values_at(:reason, :code, :to_city)
  end

  def test_malformed_bid_is_nacked_to_the_city
    processor = build

    assert_equal :done, processor.process(JSON.generate(bid('data' => { 'offerId' => 'o', 'quantity' => '7300' })),
                                          'city.HGW')
    assert_equal ['MALFORMED_MESSAGE', 422, 'HGW'], @publisher.nacks.first.values_at(:reason, :code, :to_city)
  end

  def test_api_422_on_a_bid_is_nacked_to_the_city
    processor = build(status: 422, body: '{"error":"UNKNOWN_TYPE","detail":"type \"bid\" is not supported"}')

    assert_equal :done, processor.process(JSON.generate(bid), 'city.HGW')
    assert_equal ['UNKNOWN_TYPE', 400, 'HGW'], @publisher.nacks.first.values_at(:reason, :code, :to_city)
  end

  def test_bid_rejected_is_saved_and_never_answered
    processor = build
    message = Samples.message('bid-rejected', 'data' => { 'target' => TARGET, 'offerId' => 'HGW-9431',
                                                          'available' => 100 })

    assert_equal :done, processor.process(JSON.generate(message), 'city.HGW')
    assert_equal %i[deliver], @calls
    assert(@logs.any? { |line| line.include?("La ciudad HGW rechazó #{TARGET}") })
  end

  def test_malformed_bid_rejected_is_discarded_without_answering
    processor = build
    message = Samples.message('bid-rejected', 'data' => { 'target' => TARGET })

    assert_equal :done, processor.process(JSON.generate(message), 'city.HGW')
    assert_equal %i[report_rejected], @calls
  end

  # el schema no le pone maximo al cycleId: 65 caracteres se guarda y se responde ack
  def test_long_cycle_id_is_well_formed
    processor = build

    assert_equal :done, processor.process(JSON.generate(valid_message('cycleId' => 'c' * 65)))
    assert_equal %i[deliver ack], @calls
  end

  # --- cola del mercado ---

  # la oferta oficial, de HGW
  def offer(changes = {})
    Samples.message('offer', changes)
  end

  def test_market_offer_is_saved_and_nothing_is_published
    processor = build(queue: :market)

    assert_equal :done, processor.process(JSON.generate(offer), 'city.HGW')
    assert_equal %i[deliver], @calls
    assert_empty @publisher.acks + @publisher.nacks
  end

  def test_market_malformed_or_foreign_message_is_reported_and_removed_from_the_queue
    [[offer('data' => 'x'), 'city.HGW'], [offer, 'city.XXX'], [offer, nil], [bid, 'city.HGW']].each do |message, user_id|
      processor = build(queue: :market)

      assert_equal :done, processor.process(JSON.generate(message), user_id)
      assert_equal %i[report_rejected], @calls
      assert_equal 'discard', @master.rejected.first[:kind]
      assert_empty @publisher.acks + @publisher.nacks
    end
  end

  # market-closed llega sin user_id: viaja por market.closed, que ninguna ciudad puede usar
  def test_market_closed_without_user_id_is_saved_and_nothing_is_published
    processor = build(queue: :market)

    assert_equal :done, processor.process(JSON.generate(Samples.message('market-closed')), nil)
    assert_equal %i[deliver], @calls
  end

  def test_market_message_rejected_by_the_api_is_not_answered
    processor = build(queue: :market, status: 422, body: '{"error":"UNKNOWN_TYPE"}')

    assert_equal :done, processor.process(JSON.generate(offer), 'city.HGW')
    assert_equal %i[deliver], @calls
  end

  def test_market_uses_the_same_retry_policy
    processor = build(queue: :market, status: 503)
    body = JSON.generate(offer)

    5.times { assert_equal :retry, processor.process(body, 'city.HGW') }
    assert_equal [MessageProcessor::WAIT_DELAY] * 5, @sleeps

    @master.status = 500
    3.times { assert_equal :retry, processor.process(body, 'city.HGW') }
    assert_equal :reject, processor.process(body, 'city.HGW')
    assert_equal 'MAX_RETRIES_EXCEEDED', @master.rejected.first[:reason]
  end

  def test_error_from_central_is_logged_and_nothing_is_published
    processor = build
    error = Samples.message('error', 'reason' => 'CYCLE_EXPIRED', 'code' => 410,
                                     'data' => { 'target' => TARGET, 'message' => 'x' })

    assert_equal :done, processor.process(JSON.generate(error))
    assert_empty @publisher.acks + @publisher.nacks
    assert(@logs.any? { |text| text.include?('CYCLE_EXPIRED') && text.include?('410') })
  end
end
