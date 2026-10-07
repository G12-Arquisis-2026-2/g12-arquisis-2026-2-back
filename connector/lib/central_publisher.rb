require 'json'
require 'securerandom'
require 'time'

class CentralPublisher
  # enabled: false es ENABLE_PUBLISHER apagado: no se manda nada al broker, solo se loguea
  def initialize(channel, exchange:, routing_key:, user_id:, city_id:, enabled: true,
                 log: ->(text) { puts "[Connector] #{text}" })
    @channel = channel
    @exchange = exchange
    @routing_key = routing_key
    @user_id = user_id
    @city_id = city_id
    @enabled = enabled
    @log = log
  end

  def ack(message)
    publish(envelope('ack').merge('data' => { 'target' => message['msgId'] }))
  end

  def nack(message, reason, code, detail)
    publish(failure('nack', message, reason, code, detail))
  end

  # error = el mensaje llego bien pero fallo al procesarlo. el protocolo pide que vaya despues del ack
  # del mismo mensaje, por eso el ack va aca adentro y nunca se publica un error solo.
  # si el ack revienta (canal cerrado) el error no sale
  def error(message, reason, code, detail)
    ack(message)
    publish(failure('error', message, reason, code, detail))
  end

  # para los mensajes del outbox: se publica tal cual y se espera a que el broker confirme que lo recibio
  # apagado devuelve false (no confirmado), asi nunca se marca como enviado algo que no salio
  def publish_confirmed(message)
    return false unless publish(message)

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

  def failure(type, message, reason, code, detail)
    data = { 'target' => message['msgId'], 'message' => detail.to_s }
    data['cycleId'] = message['cycleId'] if message['cycleId'].is_a?(String)

    envelope(type).merge('reason' => reason, 'code' => code, 'data' => data)
  end

  # se publica con el nombre del exchange porque no podemos declararlo. sin user_id la central lo rechaza
  # devuelve false si no se publico por tener ENABLE_PUBLISHER apagado
  def publish(message)
    unless @enabled
      @log.call("ENABLE_PUBLISHER apagado, no se publica: type=#{message['type']} " \
                "msgId=#{message['msgId']} idpk=#{message['idpk']} cityId=#{message['cityId']}")
      return false
    end

    @channel.basic_publish(
      JSON.generate(message), @exchange, @routing_key,
      user_id: @user_id, content_type: 'application/json'
    )
    true
  end
end
