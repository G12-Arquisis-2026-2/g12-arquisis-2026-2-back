require 'time'

# revisa el contenido (data) de cada tipo segun los schemas oficiales del curso
# (iic2173/energyshark-contracts, tag v3.0.2). devuelve el primer problema o nil.
#
# solo se exige lo obligatorio: un campo extra se ignora aunque el schema de la central sea "cerrado",
# porque nosotros somos el receptor (no ganamos nada rechazando un mensaje que entendemos).
# un campo terminado en "?" es opcional: puede no venir, pero si viene debe tener el tipo correcto.
module DataRules
  CITY_CODE = /\A[A-Z0-9]{3}\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/i

  # tipos simples: [como se explica el problema, como se reconoce un valor bien formado]
  SIMPLE = {
    text: ['un texto no vacío', ->(v) { v.is_a?(String) && !v.empty? }],
    string: ['un texto', ->(v) { v.is_a?(String) }],
    uuid: ['un UUID', ->(v) { DataRules.uuid?(v) }],
    instant: ['una fecha ISO 8601 con zona horaria', ->(v) { DataRules.instant?(v) }],
    city: ['un código de ciudad (3 mayúsculas o dígitos)', ->(v) { DataRules.city_code?(v) }],
    # los kWh son enteros; sin minimo, salvo donde el schema lo pide
    kwh: ['un entero', ->(v) { v.is_a?(Integer) }],
    kwh_min0: ['un entero mayor o igual a 0', ->(v) { v.is_a?(Integer) && v >= 0 }],
    int_min1: ['un entero mayor o igual a 1', ->(v) { v.is_a?(Integer) && v >= 1 }],
    # creditos (2 decimales) y tarifas (4 decimales) viajan como number
    number: ['un número', ->(v) { v.is_a?(Numeric) }],
    number_min0: ['un número mayor o igual a 0', ->(v) { v.is_a?(Numeric) && v >= 0 }],
    boolean: ['true o false', ->(v) { [true, false].include?(v) }],
    memo: ['un texto de a lo sumo 128 caracteres', ->(v) { v.is_a?(String) && v.length <= 128 }],
    operation: ['propose, accept o cancel', ->(v) { %w[propose accept cancel].include?(v) }],
    asset: ['CR o KWH', ->(v) { %w[CR KWH].include?(v) }],
    # el eco del cycleId en un nack o error de la central
    echo_cycle: ['un texto de a lo sumo 64 caracteres', ->(v) { v.is_a?(String) && v.length <= 64 }],
    # una pata de un swap: CR con monto > 0, o KWH con monto entero > 0
    asset_amount: ['{asset, amount} con CR y monto > 0, o KWH y monto entero > 0', ->(v) { DataRules.asset_amount?(v) }]
  }.freeze

  # objetos anidados: un hash de campo => tipo
  PENALTY = { 'amount' => :number, 'forCycleId' => :text }.freeze
  ENERGY = {
    'generationCapacity' => :number, 'consumption' => :number, 'generationCost' => :number, 'sellable' => :kwh_min0
  }.freeze
  LIMITS = { 'marketOpsPerMinute' => :int_min1, 'walletWritesPerMinute' => :int_min1,
             'walletReadsPerMinute' => :int_min1 }.freeze
  MARKET = {
    'buybackPrice' => :number, 'imbalancePrice' => :number, 'minBid' => :int_min1, 'opensAt' => :instant,
    'lastOfferAt' => :instant, 'lastBidAt' => :instant, 'closesAt' => :instant, 'reportOpensAt' => :instant,
    'limits' => LIMITS
  }.freeze
  ROUTE = { 'distance' => :number, 'transportCost' => :number, 'enabled' => :boolean }.freeze
  BALANCES = {
    'CR' => { 'available' => :number, 'held' => :number_min0 },
    'KWH' => { 'available' => :kwh_min0, 'held' => :kwh_min0 }
  }.freeze

  # data de cada tipo que recibimos
  DATA = {
    'status-statement' => { 'energy' => ENERGY, 'market' => MARKET, 'validUntil' => :instant },
    'transfer' => { 'quantity' => :number, 'balanceAfter' => :number, 'creditLine' => :number_min0,
                    'penalty?' => PENALTY },
    'distance-table' => { 'distances' => :distances, 'disabledRouteTransportCost' => :number },
    'trade-recorded' => {
      'swapId' => :text, 'offerId' => :string, 'seller' => :city, 'buyer' => :city, 'quantity' => :kwh,
      'pricePerEnergy' => :number, 'energyTotal' => :number, 'transportPerEnergy' => :number,
      'transportTotal' => :number, 'routeEnabled' => :boolean
    },
    'imbalance-settlement' => {
      'kwhHeld' => :kwh_min0, 'deficit' => :kwh_min0, 'coverage' => :kwh, 'pricePerEnergy' => :number,
      'total' => :number, 'balanceAfter' => :number, 'settlementId' => :uuid
    },
    'swap-proposed' => {
      'swapId' => :text, 'idpk' => :uuid, 'proposer' => :city, 'give' => :asset_amount, 'take' => :asset_amount,
      'memo' => :memo, 'expiresAt' => :instant, 'token' => :text, 'balancesAfter' => BALANCES
    },
    'swap-settled' => {
      'swapId' => :text, 'idpk' => :uuid, 'proposer' => :city, 'acceptor' => :city, 'give' => :asset_amount,
      'take' => :asset_amount, 'memo' => :memo, 'settledAt' => :instant, 'balancesAfter' => BALANCES
    },
    'swap-cancelled' => { 'swapId' => :text, 'idpk' => :uuid, 'balancesAfter' => BALANCES },
    'swap-expired' => { 'swapId' => :text, 'balancesAfter' => BALANCES },
    'swap-rejected' => {
      'idpk' => :uuid, 'operation' => :operation, 'message' => :string,
      'swapId?' => :text, 'asset?' => :asset, 'available?' => :number, 'required?' => :number
    },
    # ojo: una cantidad bajo el minBid (o 0, o negativa) esta bien formada. la API responde BID_TOO_SMALL
    'bid' => { 'offerId' => :text, 'quantity' => :kwh },
    'bid-accepted' => {
      'target' => :uuid, 'offerId' => :text, 'quantity' => :kwh, 'pricePerEnergy' => :number, 'amount' => :number,
      'swapId' => :text, 'swapToken' => :text, 'expiresAt' => :instant
    },
    'bid-rejected' => { 'target' => :uuid, 'offerId' => :text, 'message?' => :string, 'requested?' => :kwh,
                        'available?' => :kwh },
    'ack' => { 'target' => :uuid },
    'nack' => { 'target' => :uuid, 'message?' => :string },
    'error' => { 'target' => :uuid, 'message' => :string, 'cycleId?' => :echo_cycle, 'opensAt?' => :instant },
    'offer' => { 'offerId' => :text, 'quantity' => :kwh, 'pricePerEnergy' => :number },
    'offer-updated' => { 'offerId' => :text, 'remaining' => :kwh, 'pricePerEnergy' => :number },
    'offer-withdrawn' => { 'offerId' => :text },
    'market-closed' => {}
  }.freeze

  # el nack de la central es mas estricto que el de una ciudad
  CENTRAL_NACK = { 'target' => :uuid, 'message' => :string, 'cycleId?' => :echo_cycle }.freeze

  # pares (reason => code) que acepta cada tipo que lleva reason y code en el nivel superior
  REFUSALS = {
    'nack' => { 'MALFORMED_MESSAGE' => 422, 'UNKNOWN_TYPE' => 400, 'IDPK_EQUALS_MSGID' => 422,
                'IDENTITY_MISMATCH' => 403 },
    'error' => { 'CYCLE_UNKNOWN' => 404, 'CYCLE_EXPIRED' => 410, 'REPORT_TOO_EARLY' => 422, 'TYPE_RETIRED' => 410 },
    'bid-rejected' => { 'QUANTITY_UNAVAILABLE' => 409, 'OFFER_WITHDRAWN' => 410, 'BID_TOO_SMALL' => 422,
                        'MARKET_CLOSED' => 410, 'SELF_TRADE' => 422 },
    'swap-rejected' => { 'MARKET_CLOSED' => 410, 'INSUFFICIENT_ASSET' => 402, 'SWAP_NOT_PROPOSED' => 409,
                         'SWAP_EXPIRED' => 410, 'NOT_PROPOSER' => 403, 'SELF_SWAP' => 422, 'SAME_ASSET' => 422 }
  }.freeze

  # campo de data que pasa a ser obligatorio con cierto reason
  REQUIRED_BY_REASON = { 'QUANTITY_UNAVAILABLE' => 'available', 'REPORT_TOO_EARLY' => 'opensAt' }.freeze

  def self.problem(message)
    type = message['type']
    spec = type == 'nack' && message['sender'] == 'central' ? CENTRAL_NACK : DATA.fetch(type)
    refusal_problem(message) || fields_problem(message['data'], spec, 'data')
  end

  # reason y code en el nivel superior, con un par del catalogo
  def self.refusal_problem(message)
    pairs = REFUSALS[message['type']]
    return nil unless pairs

    reason = message['reason']
    return "reason #{reason.inspect} no corresponde a un #{message['type']}" unless pairs.key?(reason)
    return "code de #{reason} debe ser #{pairs[reason]}" unless message['code'] == pairs[reason]

    field = REQUIRED_BY_REASON[reason]
    "falta el campo data.#{field} (obligatorio con #{reason})" if field && message['data']&.dig(field).nil?
  end

  def self.fields_problem(hash, spec, path)
    spec.each do |key, kind|
      field = key.delete_suffix('?')
      next if key.end_with?('?') && !hash.key?(field)
      return "falta el campo #{path}.#{field}" if !key.end_with?('?') && hash[field].nil?

      problem = value_problem(hash[field], kind, "#{path}.#{field}")
      return problem if problem
    end
    nil
  end

  def self.value_problem(value, kind, path)
    return object_problem(value, kind, path) if kind.is_a?(Hash)
    return distances_problem(value, path) if kind == :distances

    explanation, valid = SIMPLE.fetch(kind)
    valid.call(value) ? nil : "#{path} debe ser #{explanation}"
  end

  def self.object_problem(value, spec, path)
    return "#{path} debe ser un objeto" unless value.is_a?(Hash)

    fields_problem(value, spec, path)
  end

  # una entrada por ciudad de destino, con su codigo como clave
  def self.distances_problem(distances, path)
    return "#{path} debe ser un objeto" unless distances.is_a?(Hash)

    distances.each do |city, route|
      return "#{path}.#{city}: la clave debe ser un código de ciudad" unless city_code?(city)

      problem = object_problem(route, ROUTE, "#{path}.#{city}")
      return problem if problem
    end
    nil
  end

  def self.asset_amount?(value)
    return false unless value.is_a?(Hash)

    amount = value['amount']
    case value['asset']
    when 'CR' then amount.is_a?(Numeric) && amount.positive?
    when 'KWH' then amount.is_a?(Integer) && amount.positive?
    else false
    end
  end

  def self.city_code?(value)
    value.is_a?(String) && CITY_CODE.match?(value)
  end

  def self.uuid?(value)
    value.is_a?(String) && UUID.match?(value)
  end

  # date-time del schema: con zona horaria (Z o +hh:mm). Time.iso8601 aceptaria una fecha sin zona
  def self.instant?(value)
    return false unless value.is_a?(String) && value.match?(/(Z|[+-]\d{2}:\d{2})\z/i)

    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end
end
