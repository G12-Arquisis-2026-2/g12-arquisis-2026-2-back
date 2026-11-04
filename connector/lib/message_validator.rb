require 'json'
require_relative 'data_rules'

# revisa cada mensaje (protocolo v3, contratos iic2173/energyshark-contracts v3.0.2) y decide que
# hacer: :discard, :nack o :accept.
# reply_to es el codigo de la ciudad a la que se responde; nil significa responder a la central.
module MessageValidator
  # de la central (traen "sender": "central")
  CENTRAL_TYPES = %w[status-statement transfer distance-table trade-recorded imbalance-settlement].freeze
  # eventos de la wallet: los reenvia la central, tambien con "sender": "central" y sin cycleId
  WALLET_TYPES = %w[swap-proposed swap-settled swap-cancelled swap-expired swap-rejected].freeze
  # de otras ciudades (traen cityId)
  PEER_TYPES = %w[bid bid-accepted].freeze
  TYPES_WITH_ACK = (CENTRAL_TYPES + WALLET_TYPES + PEER_TYPES).freeze

  # nunca se responden. bid-rejected es un error en el sentido de la E1
  NO_REPLY_TYPES = %w[ack nack error bid-rejected].freeze
  # respuestas de la E1 (ack/nack de la central o de una ciudad, error de la central)
  REPLY_TYPES = %w[ack nack error].freeze

  # feed publico de la cola market.TK3: se guarda y no se responde nunca
  MARKET_TYPES = %w[offer offer-updated offer-withdrawn market-closed].freeze

  # quien puede enviar cada tipo (x-amqp.sender de cada schema). ack y nack los envian los dos
  FROM_CENTRAL = (CENTRAL_TYPES + WALLET_TYPES + %w[error market-closed]).freeze
  FROM_CITY = (PEER_TYPES + %w[bid-rejected offer offer-updated offer-withdrawn]).freeze

  # los que incluyen common/cycle-bound en su schema
  TYPES_WITH_CYCLE = %w[
    status-statement transfer distance-table trade-recorded imbalance-settlement
    bid bid-accepted bid-rejected offer offer-updated offer-withdrawn market-closed
  ].freeze
  # solo para el eco en nuestro nack: el schema no le pone maximo al cycleId de un mensaje
  MAX_ECHO_CYCLE_ID = 64

  # toda ciudad publica con user_id city.{CODE}; la central, con user_id central
  CITY_USER = /\Acity\.([A-Z0-9]{3})\z/
  CENTRAL_USER = 'central'.freeze

  Decision = Struct.new(:action, :message, :send_ack, :reason, :code, :detail, :reply_to, keyword_init: true)

  # user_id: la propiedad AMQP user_id del mensaje. queue: :city o :market
  def self.check(raw_body, user_id = nil, queue: :city)
    message = parse(raw_body)
    return discard('el cuerpo no es un objeto JSON') if message.nil?
    return discard('el mensaje no trae msgId', message) unless text?(message['msgId'])

    return check_market(message, user_id) if queue == :market
    return discard_forged_central(message, user_id) if forged_central?(message, user_id)
    return check_no_reply(message, user_id) if NO_REPLY_TYPES.include?(message['type'])

    check_with_reply(message, user_id)
  rescue StandardError => e
    # pase lo que pase check no tira excepcion, se descarta y listo
    discard("no se pudo revisar el mensaje (#{e.class})")
  end

  # en city.TK3 la central siempre publica con user_id "central". el broker no deja usar un user_id
  # ajeno, asi que uno que dice venir de la central sin ese user_id no lo publico ella:
  # se descarta sin responder (README v3.0.2, "user_id en los mensajes de la central")
  def self.forged_central?(message, user_id)
    message['sender'] == 'central' && message['cityId'].nil? && user_id != CENTRAL_USER
  end

  def self.discard_forged_central(message, user_id)
    discard("dice venir de la central pero llegó con user_id #{user_id.inspect}; no se responde",
            message, reason: 'IDENTITY_MISMATCH')
  end

  def self.check_with_reply(message, user_id)
    reply_to = reply_target(message, user_id)
    problem = problem_in(message, user_id, TYPES_WITH_ACK)
    return accept(message, send_ack: true, reply_to: reply_to) unless problem

    # dice venir de una ciudad pero no sabemos a cual responderle (cityId mal escrito y sin user_id)
    if reply_to.nil? && user_id != CENTRAL_USER && !message['cityId'].nil?
      return discard("#{problem[0]}: #{problem[2]} (no se responde: no se sabe qué ciudad lo envió)",
                     message, reason: problem[0])
    end

    nack(message, *problem, reply_to)
  end

  # se responde a quien lo publico de verdad, segun user_id: una ciudad o la central (nil).
  # sin un user_id conocido, a la ciudad que dice ser (la unica a la que se puede responder)
  def self.reply_target(message, user_id)
    return sender_city(user_id) if sender_city(user_id)
    return nil if user_id == CENTRAL_USER

    DataRules.city_code?(message['cityId']) ? message['cityId'] : nil
  end

  def self.check_no_reply(message, user_id)
    problem = problem_in(message, user_id, NO_REPLY_TYPES)
    if problem
      return discard("#{message['type']} inválido, no se responde. #{problem[0]}: #{problem[2]}",
                     message, reason: problem[0])
    end

    accept(message, send_ack: false)
  end

  # market-closed llega sin user_id (viaja por market.closed, que ninguna ciudad puede usar).
  # las ofertas si traen user_id, y debe ser city.{cityId}
  def self.check_market(message, user_id)
    problem = problem_in(message, user_id, MARKET_TYPES)
    if problem
      return discard("mensaje del mercado inválido. #{problem[0]}: #{problem[2]}", message, reason: problem[0])
    end

    accept(message, send_ack: false)
  end

  # devuelve [reason, code, detalle] del primer problema, o nil si esta todo bien
  def self.problem_in(message, user_id, known_types)
    detail = envelope_problem(message)
    return malformed(detail) if detail
    return ['IDPK_EQUALS_MSGID', 422, 'idpk debe ser distinto de msgId'] if message['idpk'] == message['msgId']

    detail = identity_problem(message, user_id)
    return ['IDENTITY_MISMATCH', 403, detail] if detail
    return ['UNKNOWN_TYPE', 400, "tipo desconocido: #{message['type']}"] unless known_types.include?(message['type'])

    detail = content_problem(message)
    malformed(detail) if detail
  end

  # decisiones

  # reason: en un descarte es solo informativo (para el log y /events/rejected)
  def self.discard(detail, message = nil, reason: nil)
    Decision.new(action: :discard, message: message, detail: detail, reason: reason)
  end

  def self.nack(message, reason, code, detail, reply_to = nil)
    Decision.new(action: :nack, message: message, reason: reason, code: code, detail: detail, reply_to: reply_to)
  end

  def self.accept(message, send_ack:, reply_to: nil)
    Decision.new(action: :accept, message: message, send_ack: send_ack, reply_to: reply_to)
  end

  def self.malformed(detail)
    ['MALFORMED_MESSAGE', 422, detail]
  end

  # revisiones

  # devuelve el mensaje como hash o nil si no es un objeto JSON.
  def self.parse(raw_body)
    # si los bytes no son utf-8 valido se descarta altiro, si no despues revienta el strip
    text = raw_body.to_s.dup.force_encoding('UTF-8')
    return nil unless text.valid_encoding?

    parsed = JSON.parse(text)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError, TypeError, EncodingError
    nil
  end

  # common/envelope: idpk y msgId son UUID, timestamp es date-time con zona
  def self.envelope_problem(message)
    return 'falta el campo idpk' unless text?(message['idpk'])
    return 'idpk debe ser un UUID' unless DataRules.uuid?(message['idpk'])
    return 'msgId debe ser un UUID' unless DataRules.uuid?(message['msgId'])
    return 'falta el campo type' unless text?(message['type'])

    problem = emitter_problem(message)
    return problem if problem
    return 'falta el campo timestamp' unless text?(message['timestamp'])
    return 'timestamp debe ser una fecha ISO 8601 con zona horaria' unless DataRules.instant?(message['timestamp'])

    nil
  end

  # la central trae sender "central"; una ciudad trae cityId. nunca los dos
  def self.emitter_problem(message)
    from_city = !message['cityId'].nil?
    from_central = !message['sender'].nil?
    return 'falta el emisor: no trae sender ni cityId' unless from_city || from_central
    return 'no puede traer sender y cityId a la vez' if from_city && from_central
    if from_city && !DataRules.city_code?(message['cityId'])
      return 'cityId debe ser un código de ciudad (3 mayúsculas o dígitos)'
    end
    return 'sender solo puede ser "central"' if from_central && message['sender'] != 'central'

    nil
  end

  # el broker no deja publicar con un user_id distinto del usuario conectado, por eso es confiable.
  # un mensaje de ciudad sin user_id o con uno que no calza es IDENTITY_MISMATCH
  def self.identity_problem(message, user_id)
    city_id = message['cityId']
    if city_id.nil?
      # dice venir de la central: en la cola del mercado, que lo haya publicado una ciudad
      return sender_city(user_id) ? "user_id #{user_id} es de una ciudad, no de la central" : nil
    end
    return nil if user_id == "city.#{city_id}"

    "user_id #{user_id.inspect} no corresponde a cityId #{city_id}"
  end

  def self.content_problem(message)
    type = message['type']
    return "#{type} solo lo puede enviar la central" if FROM_CENTRAL.include?(type) && message['sender'].nil?
    return "#{type} solo lo puede enviar una ciudad" if FROM_CITY.include?(type) && message['cityId'].nil?

    cycle_problem(message) || data_problem(message)
  end

  # common/cycle-bound: un texto de al menos 1 caracter, sin maximo. null, "" o un numero no sirven
  def self.cycle_problem(message)
    return nil unless TYPES_WITH_CYCLE.include?(message['type'])

    cycle_id = message['cycleId']
    cycle_id.is_a?(String) && !cycle_id.empty? ? nil : 'falta el campo cycleId'
  end

  def self.data_problem(message)
    return 'data debe ser un objeto' unless message['data'].is_a?(Hash)

    DataRules.problem(message)
  end

  # lo usa el nack: el cycleId solo se devuelve si es un texto de a lo sumo 64 caracteres
  def self.echo_cycle_id?(value)
    value.is_a?(String) && !value.empty? && value.length <= MAX_ECHO_CYCLE_ID
  end

  def self.sender_city(user_id)
    match = CITY_USER.match(user_id.to_s)
    match && match[1]
  end

  def self.text?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end
