# Deja un mensaje listo para que el connector lo publique: a la central, a otra ciudad o al mercado.
#
# No abre ninguna conexión al broker: solo guarda el mensaje como pendiente.
# Así, si el broker se cae, la API sigue funcionando y el mensaje no se pierde.
#
# El archivo se llama rabbit_m_q_publisher.rb porque Rails busca la clase
# RabbitMQPublisher (con MQ en mayúsculas) en un archivo con ese nombre.
class RabbitMQPublisher
  MARKET_EXCHANGE = "market".freeze

  # payload: hash con type y data, y opcionalmente cycleId, idpk y msgId.
  # idpk: se pasa cuando es un reintento, para repetir el idpk original.
  # Destino (opcional; sin destino va a la central, como en la E1):
  #   to_city: "HGW"   -> a otra ciudad (bid, bid-accepted, bid-rejected), routing key city.HGW
  #   to_market: true  -> al mercado (offer, offer-updated, offer-withdrawn), routing key market.offer.<CITY_ID>
  # Devuelve el msgId, que sirve para reconocer la respuesta (ack/nack).
  # Acepta el hash como argumento (como lo llaman los jobs) o los campos sueltos.
  def self.publish(payload = nil, idpk: nil, to_city: nil, to_market: false, **fields)
    message = build_envelope((payload || fields).to_h.deep_stringify_keys, idpk)
    exchange, routing_key = destination(to_city, to_market)

    enqueue(message, exchange, routing_key, replied_bid_idpk(message))
  end

  # Bid repetido (mismo idpk): se vuelve a enviar la respuesta que ya dimos (anomalía 1).
  # bid: el payload del bid repetido. La copia lleva el mismo idpk de la respuesta original
  # (es la misma operación), un msgId nuevo y data.target igual al msgId del bid repetido.
  # Si todavía no hay respuesta (se está decidiendo) no se encola nada: la original saldrá sola.
  # Devuelve el msgId de la copia, o nil si no había respuesta.
  def self.resend_bid_reply(bid)
    bid = bid.to_h.deep_stringify_keys
    original = OutboxMessage.reply_to_bid(bid.fetch("idpk"))
    return unless original

    copy = original.payload.merge(
      "msgId" => SecureRandom.uuid,
      "timestamp" => Time.now.utc.iso8601,
      "data" => original.payload["data"].merge("target" => bid.fetch("msgId"))
    )
    enqueue(copy, original.exchange, original.routing_key, original.reply_to_idpk)
  end

  def self.enqueue(message, exchange, routing_key, reply_to_idpk)
    OutboxMessage.create!(
      msg_id: message["msgId"],
      idpk: message["idpk"],
      message_type: message["type"],
      payload: message,
      exchange: exchange,
      routing_key: routing_key,
      reply_to_idpk: reply_to_idpk
    )
    message["msgId"]
  end

  # bid-accepted y bid-rejected apuntan al bid por su msgId (data.target); se guarda su idpk,
  # que es lo que se repite cuando el bid llega duplicado.
  def self.replied_bid_idpk(message)
    return unless OutboxMessage::BID_REPLY_TYPES.include?(message["type"])

    MarketBid.find_by(bid_msg_id: message.dig("data", "target"))&.bid_idpk
  end

  # [exchange, routing_key]. exchange nil = el de siempre (RABBITMQ_EXCHANGE del connector).
  # El formato de la routing key de otra ciudad es el mismo PEER_ROUTING_KEY_FORMAT del connector.
  def self.destination(to_city, to_market)
    raise ArgumentError, "un mensaje va a una ciudad o al mercado, no a los dos" if to_city.present? && to_market
    return [MARKET_EXCHANGE, "market.offer.#{ENV.fetch('CITY_ID')}"] if to_market
    return [nil, format(ENV.fetch("PEER_ROUTING_KEY_FORMAT", "city.%s"), to_city)] if to_city.present?

    [nil, nil]
  end

  def self.build_envelope(given, idpk)
    message = {
      "msgId" => given["msgId"].presence || SecureRandom.uuid,
      "idpk" => idpk.presence || given["idpk"].presence || SecureRandom.uuid,
      "type" => given.fetch("type"),
      "timestamp" => Time.now.utc.iso8601,
      # Siempre el de CITY_ID: la central rechaza un cityId que no sea el de nuestro usuario.
      "cityId" => ENV.fetch("CITY_ID")
    }
    message["cycleId"] = given["cycleId"] if given["cycleId"].present?
    # bid-rejected lleva reason y code en el nivel superior, como un nack (ej: QUANTITY_UNAVAILABLE)
    if message["type"] == "bid-rejected"
      message["reason"] = given["reason"] if given.key?("reason")
      message["code"] = given["code"] if given.key?("code")
    end
    message["data"] = plain_numbers(given["data"] || {})

    raise ArgumentError, "msgId e idpk deben ser distintos" if message["msgId"] == message["idpk"]

    message
  end

  # Los saldos vienen como BigDecimal y en JSON se guardarían como texto ("0.0").
  # La central espera números, así que se convierten antes de guardar.
  def self.plain_numbers(value)
    case value
    when BigDecimal then value.to_f
    when Hash then value.transform_values { |item| plain_numbers(item) }
    when Array then value.map { |item| plain_numbers(item) }
    else value
    end
  end
end
