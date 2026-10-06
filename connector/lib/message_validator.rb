require 'json'
require 'time'
 
# Revisa cada mensaje que llega desde el broker y decide que hacer con el.
# hay 3 opciones:
# :discard no se puede leer o no trae msgId, se registra y no se responde.
# :nack se puede leer pero está mal, se responde con un nack.
# :accept  está bien. Se entrega a master. Si `send_ack` es true, se repsonde con un ack

module MessageValidator
  # mensajes q respondemos con un ack.
  TYPES_WITH_ACK = %w[
    status-statement transfer demand-statement distance-table give take demand-set
  ].freeze
 
  # Respuestas de la central, se procesan pero nunca se responden
  REPLY_TYPES = %w[ack nack error].freeze
 
  # Tipos que deben nombrar un ciclo (cycleId).
  TYPES_WITH_CYCLE = %w[status-statement transfer demand-statement give take].freeze
 
  Decision = Struct.new(:action, :message, :send_ack, :reason, :code, :detail, keyword_init: true)
 
  def self.check(raw_body)
    message = parse(raw_body)
    return discard('el cuerpo no es un objeto JSON') if message.nil?
    return discard('el mensaje no trae msgId', message) unless text?(message['msgId'])
 
    if REPLY_TYPES.include?(message['type'])
      problem = envelope_problem(message)
      return discard("respuesta inválida de la central: #{problem}", message) if problem
 
      return accept(message, send_ack: false)
    end
 
    problem = envelope_problem(message)
    return nack(message, 'MALFORMED_MESSAGE', 422, problem) if problem
 
    if message['idpk'] == message['msgId']
      return nack(message, 'IDPK_EQUALS_MSGID', 422, 'idpk debe ser distinto de msgId')
    end
 
    unless TYPES_WITH_ACK.include?(message['type'])
      return nack(message, 'UNKNOWN_TYPE', 400, "tipo desconocido: #{message['type']}")
    end
 
    problem = content_problem(message)
    return nack(message, 'MALFORMED_MESSAGE', 422, problem) if problem
 
    accept(message, send_ack: true)
  end
 
  # decisiones
 
  def self.discard(detail, message = nil)
    Decision.new(action: :discard, message: message, detail: detail)
  end
 
  def self.nack(message, reason, code, detail)
    Decision.new(action: :nack, message: message, reason: reason, code: code, detail: detail)
  end
 
  def self.accept(message, send_ack:)
    Decision.new(action: :accept, message: message, send_ack: send_ack)
  end
 
  # revisiones
 
  # devuelve el mensaje como hash o nil si no es un objeto JSON.
  def self.parse(raw_body)
    parsed = JSON.parse(raw_body)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError, TypeError, EncodingError
    nil
  end
 
  # devuelve nil si esta todo bien (minimo los campos idpk, msgId, type y timestamp)
  def self.envelope_problem(message)
    %w[idpk type timestamp].each do |field|
      return "falta el campo #{field}" unless text?(message[field])
    end
    return 'timestamp debe ser una fecha ISO 8601' unless iso8601?(message['timestamp'])
 
    nil
  end
 
  # Revisa el contenido (data) según el tipo
  def self.content_problem(message)
    type = message['type']
    data = message['data']
 
    return 'falta el campo cycleId' if TYPES_WITH_CYCLE.include?(type) && !text?(message['cycleId'])
    return 'data debe ser un objeto' unless data.is_a?(Hash)
 
    case type
    when 'status-statement'
      energy = data['energy']
      return 'data.energy debe ser un objeto' unless energy.is_a?(Hash)
 
      number_problem(energy, %w[generationCapacity consumption generationCost], 'data.energy')
    when 'transfer'
      number_problem(data, %w[quantity], 'data')
    when 'demand-statement'
      balance = data['balance']
      return 'data.balance debe ser un objeto' unless balance.is_a?(Hash)
 
      number_problem(balance, %w[quantity valuePerKwh], 'data.balance')
    when 'give', 'take'
      return 'falta el campo data.target' unless text?(data['target'])
 
      number_problem(data, %w[energy pricePerEnergy], 'data')
    when 'distance-table'
      distances_problem(data['distances'])
    end
  end
 
  def self.distances_problem(distances)
    return 'data.distances debe ser un objeto' unless distances.is_a?(Hash)
 
    distances.each do |city, route|
      path = "data.distances.#{city}"
      return "#{path} debe ser un objeto" unless route.is_a?(Hash)
 
      problem = number_problem(route, %w[distance transportCost], path)
      return problem if problem
      return "#{path}.enabled debe ser true o false" unless [true, false].include?(route['enabled'])
    end
    nil
  end
 
  # devuelve el problema del primer campo que no sea un número, o nil.
  def self.number_problem(hash, fields, path)
    bad = fields.find { |field| !hash[field].is_a?(Numeric) }
    bad ? "#{path}.#{bad} debe ser un número" : nil
  end
 
  def self.text?(value)
    value.is_a?(String) && !value.strip.empty?
  end
 
  def self.iso8601?(value)
    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end
end