# Deja un mensaje listo para que el connector lo publique hacia la central.
#
# No abre ninguna conexión al broker: solo guarda el mensaje como pendiente.
# Así, si el broker se cae, la API sigue funcionando y el mensaje no se pierde.
#
# El archivo se llama rabbit_m_q_publisher.rb porque Rails busca la clase
# RabbitMQPublisher (con MQ en mayúsculas) en un archivo con ese nombre.
class RabbitMQPublisher
  # payload: hash con type y data, y opcionalmente cycleId, idpk y msgId.
  # idpk: se pasa cuando es un reintento, para repetir el idpk original.
  # Devuelve el msgId, que sirve para reconocer la respuesta de la central.
  # Acepta el hash como argumento (como lo llaman los jobs) o los campos sueltos.
  def self.publish(payload = nil, idpk: nil, **fields)
    message = build_envelope((payload || fields).to_h.deep_stringify_keys, idpk)

    OutboxMessage.create!(
      msg_id: message["msgId"],
      idpk: message["idpk"],
      message_type: message["type"],
      payload: message
    )
    message["msgId"]
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
