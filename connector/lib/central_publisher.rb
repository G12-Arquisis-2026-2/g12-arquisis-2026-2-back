require 'json'
require 'securerandom'
require 'time'

class CentralPublisher
  def initialize(channel, exchange:, routing_key:, user_id:, city_id:)
    @channel = channel
    @exchange = exchange
    @routing_key = routing_key
    @user_id = user_id
    @city_id = city_id
  end

  def ack(message)
    publish(envelope('ack').merge('data' => { 'target' => message['msgId'] }))
  end

  def nack(message, reason, code, detail)
    data = { 'target' => message['msgId'], 'message' => detail.to_s }
    data['cycleId'] = message['cycleId'] if message['cycleId'].is_a?(String)

    publish(envelope('nack').merge('reason' => reason, 'code' => code, 'data' => data))
  end

  # para los mensajes del outbox: se publica tal cual y se espera a que el broker confirme que lo recibio
  def publish_confirmed(message)
    publish(message)
    @channel.wait_for_confirms
  end

  private

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
  def publish(message)
    @channel.basic_publish(
      JSON.generate(message), @exchange, @routing_key,
      user_id: @user_id, content_type: 'application/json'
    )
  end
end
