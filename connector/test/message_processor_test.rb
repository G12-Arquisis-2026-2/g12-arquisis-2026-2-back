require 'minitest/autorun'
require 'json'
require_relative '../lib/master_client'
require_relative '../lib/message_processor'

# correr desde /connector: ruby test/message_processor_test.rb
class MessageProcessorTest < Minitest::Test
  class FakeMaster
    attr_reader :delivered, :rejected

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
    @master = FakeMaster.new(@calls, **master_options)
    @publisher = FakePublisher.new(@calls)
    MessageProcessor.new(master: @master, publisher: @publisher, log: ->(text) { @logs << text })
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
end
