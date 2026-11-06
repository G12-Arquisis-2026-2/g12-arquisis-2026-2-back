require 'json'
require 'securerandom'
require 'time'
require_relative 'message_validator'

# publica en el broker: ack/nack a la central o a otra ciudad, y los pendientes del outbox a su destino.
# (se llama CentralPublisher porque en la E1 solo le hablaba a la central)
class CentralPublisher
  # enabled: false es ENABLE_PUBLISHER apagado: no se manda nada al broker, solo se loguea
  # peer_routing_key_format: routing key de otra ciudad, "city.%s" -> city.HGW (PEER_ROUTING_KEY_FORMAT)
  # open_channel: como abrir un canal nuevo si el broker cierra este (solo lo usa el outbox)
  def initialize(channel, exchange:, routing_key:, user_id:, city_id:, peer_routing_key_format: 'city.%s',
                 enabled: true, log: ->(text) { puts "[Connector] #{text}" }, open_channel: nil)
    @channel = channel
    @open_channel = open_channel
    @exchange = exchange
    @routing_key = routing_key
    @user_id = user_id
    @city_id = city_id
    @peer_format = peer_routing_key_format
    @enabled = enabled
    @log = log
  end

  # to_city: codigo de la ciudad que envio el mensaje. nil = la central (o la wallet)
  def ack(message, to_city: nil)
    publish(envelope('ack').merge('data' => { 'target' => message['msgId'] }), @exchange, routing_key_for(to_city))
  end

  def nack(message, reason, code, detail, to_city: nil)
    data = { 'target' => message['msgId'], 'message' => detail.to_s }
    # el cycleId se devuelve solo si es un texto de a lo sumo 64 caracteres (null, numero o mas largo no)
    data['cycleId'] = message['cycleId'] if MessageValidator.echo_cycle_id?(message['cycleId'])

    reply = envelope('nack').merge('reason' => reason, 'code' => code, 'data' => data)
    publish(reply, @exchange, routing_key_for(to_city))
  end

  # para los mensajes del outbox: se publica tal cual y se espera a que el broker confirme que lo recibio
  # sin exchange ni routing key va a la central, como en la E1.
  # apagado devuelve false (no confirmado), asi nunca se marca como enviado algo que no salio
  def publish_confirmed(message, exchange: nil, routing_key: nil)
    return false unless publish(message, exchange || @exchange, routing_key || @routing_key)

    @channel.wait_for_confirms
  end

  def channel_open?
    @channel.open?
  end

  # motivo con que el broker cerro el canal (ej: "ACCESS_REFUSED - ..."), o nil si sigue abierto o si
  # se cerro por un corte de red. bunny no expone el motivo, pero lo guarda al recibir el channel.close
  def closed_by_broker
    return nil if @channel.open?

    @channel.instance_variable_get(:@last_channel_error)&.message
  end

  # un canal que cerro el broker bunny no lo recupera: hay que abrir otro
  def reopen_channel
    @channel = @open_channel.call
  end

  private

  def routing_key_for(city)
    city ? format(@peer_format, city) : @routing_key
  end

  # msgId e idpk siempre nuevos, nunca se reusan los del mensaje que estamos respondiendo
  def envelope(type)
    {
      'msgId' => SecureRandom.uuid,
      'idpk' => SecureRandom.uuid,
      'type' => type,
      'timestamp' => Time.now.utc.iso8601,
      'cityId' => @city_id
    }
  end

  # se publica con el nombre del exchange porque no podemos declararlo. sin user_id la central lo rechaza
  # devuelve false si no se publico por tener ENABLE_PUBLISHER apagado
  def publish(message, exchange, routing_key)
    unless @enabled
      @log.call("ENABLE_PUBLISHER apagado, no se publica: type=#{message['type']} " \
                "msgId=#{message['msgId']} idpk=#{message['idpk']} cityId=#{message['cityId']} " \
                "routingKey=#{routing_key}")
      return false
    end

    @channel.basic_publish(
      JSON.generate(message), exchange, routing_key,
      user_id: @user_id, content_type: 'application/json'
    )
    true
  end
end
