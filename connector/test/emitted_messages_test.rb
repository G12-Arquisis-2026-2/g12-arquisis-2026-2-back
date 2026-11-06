require 'minitest/autorun'
require 'json'
require 'fileutils'
require_relative '../lib/central_publisher'
require_relative '../lib/master_client'
require_relative '../lib/message_processor'
require_relative 'support/samples'

# contract test de lo que EMITIMOS (contract_examples_test.rb prueba lo que aceptamos).
# arma los ack y nack con el flujo real (MessageProcessor -> MessageValidator -> CentralPublisher);
# solo el canal del broker y la API son de mentira. si EMITTED_MESSAGES_DIR esta definida, escribe
# cada mensaje publicado como <type>--<routing key>--<caso>.json en esa carpeta, y
# contract-tests/validate-contracts.mjs los valida con el validador oficial del curso.
# sin la variable no escribe nada (asi corre igual en ci.yml).
# correr desde /connector: EMITTED_MESSAGES_DIR=/tmp/emitidos ruby test/emitted_messages_test.rb
class EmittedMessagesTest < Minitest::Test
  CITY = 'TK3'.freeze
  OUT_DIR = ENV.fetch('EMITTED_MESSAGES_DIR', '').strip

  class FakeChannel
    attr_reader :published

    def initialize
      @published = []
    end

    def basic_publish(payload, exchange, routing_key, options = {})
      @published << { payload: payload, exchange: exchange, routing_key: routing_key, options: options }
    end
  end

  # la API responde 201 a todo: el mensaje se entrega y se le hace ack
  class FakeMaster
    def deliver(_message)
      MasterClient::Result.new(201, '{}')
    end

    def report_rejected(**)
      MasterClient::Result.new(201, '{}')
    end
  end

  def setup
    @channel = FakeChannel.new
    publisher = CentralPublisher.new(
      @channel, exchange: 'energy.x', routing_key: 'central', user_id: "city.#{CITY}", city_id: CITY,
                peer_routing_key_format: 'city.%s', log: ->(_) {}
    )
    @processor = MessageProcessor.new(master: FakeMaster.new, publisher: publisher, queue: :city,
                                      log: ->(_) {}, sleeper: ->(_) {})
  end

  # procesa el mensaje entrante y devuelve la unica respuesta que publicamos, ya escrita en OUT_DIR
  def reply_to(incoming, user_id, label)
    assert_equal :done, @processor.process(JSON.generate(incoming), user_id, "city.#{CITY}")
    assert_equal 1, @channel.published.size, 'se esperaba exactamente una respuesta'

    sent = @channel.published.last
    assert_equal 'energy.x', sent[:exchange]
    assert_equal "city.#{CITY}", sent[:options][:user_id]
    message = JSON.parse(sent[:payload])
    assert_equal incoming['msgId'], message.dig('data', 'target')
    refute_equal message['msgId'], message['idpk']
    write(message, sent[:routing_key], label)
    message
  end

  def write(message, routing_key, label)
    return if OUT_DIR.empty?

    FileUtils.mkdir_p(OUT_DIR)
    path = File.join(OUT_DIR, "#{message['type']}--#{routing_key}--#{label}.json")
    File.write(path, "#{JSON.pretty_generate(message)}\n")
  end

  def central_message
    Samples.message('status-statement')
  end

  # un bid de otra ciudad (COR en el ejemplo oficial)
  def peer_bid(changes = {})
    Samples.message('bid', changes)
  end

  def test_ack_a_la_central
    message = reply_to(central_message, 'central', 'status-statement')

    assert_equal 'ack', message['type']
    assert_equal 'central', @channel.published.last[:routing_key]
  end

  def test_ack_a_otra_ciudad
    bid = peer_bid
    message = reply_to(bid, "city.#{bid['cityId']}", 'bid')

    assert_equal 'ack', message['type']
    assert_equal "city.#{bid['cityId']}", @channel.published.last[:routing_key]
  end

  def test_nack_a_la_central_con_eco_de_cycle_id
    incoming = central_message.merge('data' => 'no es un objeto')
    message = reply_to(incoming, 'central', 'malformed-message-cycle-echo')

    assert_equal 'central', @channel.published.last[:routing_key]
    assert_equal ['MALFORMED_MESSAGE', 422], [message['reason'], message['code']]
    assert_equal incoming['cycleId'], message.dig('data', 'cycleId')
  end

  # 65 caracteres: el cycleId es valido para el schema (no tiene maximo) pero no se devuelve
  def test_nack_a_otra_ciudad_sin_eco_de_cycle_id_invalido
    bid = peer_bid('type' => 'bid-v9', 'cycleId' => 'c' * 65)
    message = reply_to(bid, "city.#{bid['cityId']}", 'unknown-type-no-echo')

    assert_equal "city.#{bid['cityId']}", @channel.published.last[:routing_key]
    assert_equal ['UNKNOWN_TYPE', 400], [message['reason'], message['code']]
    refute message['data'].key?('cycleId')
  end

  # el bid dice ser de COR pero lo publico XYZ: se le responde a quien lo publico de verdad
  def test_nack_identity_mismatch
    bid = peer_bid
    message = reply_to(bid, 'city.XYZ', 'identity-mismatch')

    assert_equal 'city.XYZ', @channel.published.last[:routing_key]
    assert_equal ['IDENTITY_MISMATCH', 403], [message['reason'], message['code']]
    assert_equal bid['cycleId'], message.dig('data', 'cycleId')
  end
end
