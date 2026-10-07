require 'minitest/autorun'
require 'json'
require 'time'
require_relative '../lib/central_publisher'

# correr desde /connector: ruby test/central_publisher_test.rb
class CentralPublisherTest < Minitest::Test
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class FakeChannel
    attr_reader :published

    def initialize
      @published = []
    end

    def basic_publish(payload, exchange, routing_key, options = {})
      @published << { payload: payload, exchange: exchange, routing_key: routing_key, options: options }
    end

    def wait_for_confirms
      @confirms_asked = true
    end

    def confirms_asked?
      @confirms_asked == true
    end
  end

  ORIGINAL = {
    'msgId' => '11111111-1111-4111-8111-111111111111',
    'idpk' => '22222222-2222-4222-8222-222222222222',
    'type' => 'transfer',
    'cycleId' => 'cycle-9431'
  }.freeze

  def setup
    @channel = FakeChannel.new
    @publisher = CentralPublisher.new(
      @channel, exchange: 'energy.x', routing_key: 'central', user_id: 'city.12', city_id: '12'
    )
  end

  def last_message
    JSON.parse(@channel.published.last[:payload])
  end

  def assert_envelope(message, type)
    assert_equal type, message['type']
    assert_equal '12', message['cityId']
    assert_match UUID, message['msgId']
    assert_match UUID, message['idpk']
    refute_equal message['msgId'], message['idpk']
    refute_includes ORIGINAL.values, message['msgId']
    refute_includes ORIGINAL.values, message['idpk']
    assert Time.iso8601(message['timestamp'])
  end

  def test_ack_format
    @publisher.ack(ORIGINAL)

    assert_envelope(last_message, 'ack')
    assert_equal({ 'target' => ORIGINAL['msgId'] }, last_message['data'])
    assert_equal %w[cityId data idpk msgId timestamp type], last_message.keys.sort
  end

  def test_nack_format
    @publisher.nack(ORIGINAL, 'UNKNOWN_TYPE', 400, 'tipo desconocido: x')

    assert_envelope(last_message, 'nack')
    assert_equal 'UNKNOWN_TYPE', last_message['reason']
    assert_equal 400, last_message['code']
    assert_equal(
      { 'target' => ORIGINAL['msgId'], 'message' => 'tipo desconocido: x', 'cycleId' => 'cycle-9431' },
      last_message['data']
    )
  end

  def test_nack_omits_cycle_id_when_original_had_none
    original = ORIGINAL.reject { |key, _| key == 'cycleId' }
    @publisher.nack(original, 'MALFORMED_MESSAGE', 422, 'falta el campo cycleId')

    refute last_message['data'].key?('cycleId')
  end

  def test_publishes_to_exchange_by_name_with_user_id
    @publisher.ack(ORIGINAL)
    published = @channel.published.last

    assert_equal 'energy.x', published[:exchange]
    assert_equal 'central', published[:routing_key]
    assert_equal 'city.12', published[:options][:user_id]
  end

  def test_each_reply_gets_new_ids
    @publisher.ack(ORIGINAL)
    @publisher.ack(ORIGINAL)
    first, second = @channel.published.map { |item| JSON.parse(item[:payload]) }

    refute_equal first['msgId'], second['msgId']
    refute_equal first['idpk'], second['idpk']
  end

  def test_publish_confirmed_sends_the_message_as_is_and_returns_the_broker_answer
    message = { 'msgId' => 'a', 'idpk' => 'b', 'type' => 'negotiation-report', 'cityId' => '12' }

    assert_equal true, @publisher.publish_confirmed(message)
    assert_equal message, last_message
    assert_equal 'city.12', @channel.published.last[:options][:user_id]
    assert_equal 'central', @channel.published.last[:routing_key]
  end

  def disabled_publisher
    @logs = []
    CentralPublisher.new(@channel, exchange: 'energy.x', routing_key: 'central', user_id: 'city.12', city_id: '12',
                                   enabled: false, log: ->(text) { @logs << text })
  end

  def test_disabled_publish_confirmed_does_not_touch_the_broker_and_logs
    message = { 'msgId' => 'a', 'idpk' => 'b', 'type' => 'negotiation-report', 'cityId' => '12',
                'data' => { 'budgetBalance' => 10 } }

    assert_equal false, disabled_publisher.publish_confirmed(message)
    assert_empty @channel.published
    refute @channel.confirms_asked?
    assert_equal ['ENABLE_PUBLISHER apagado, no se publica: type=negotiation-report msgId=a idpk=b cityId=12'], @logs
  end

  def test_disabled_ack_and_nack_are_only_logged
    publisher = disabled_publisher
    publisher.ack(ORIGINAL)
    publisher.nack(ORIGINAL, 'UNKNOWN_TYPE', 400, 'tipo desconocido: x')

    assert_empty @channel.published
    assert_equal 2, @logs.size
    assert_includes @logs.first, 'type=ack'
    assert_includes @logs.last, 'type=nack'
  end

  def test_enabled_is_the_default_and_publishes
    @publisher.ack(ORIGINAL)

    assert_equal 1, @channel.published.size
  end
end
