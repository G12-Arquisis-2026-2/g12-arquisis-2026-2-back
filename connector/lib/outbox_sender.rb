require_relative 'message_validator'
require_relative 'rate_limiter'

# publica los mensajes que la API dejo pendientes (outbox): a la central, a otra ciudad o al mercado
class OutboxSender
  REQUIRED_FIELDS = %w[msgId idpk type timestamp].freeze
  MARKET_EXCHANGE = 'market'.freeze
  # la central limita offer + offer-updated + offer-withdrawn (status-statement:
  # data.market.limits.marketOpsPerMinute, 60 en los ejemplos). aca contamos tambien los bids para
  # no inundar a otra ciudad, y dejamos margen: los ack/nack que respondemos no pasan por aca
  MARKET_LIMIT_PER_MINUTE = 50

  # kind: :central, :city, :market o :unknown. exchange/routing_key nil = los de la central
  Destination = Struct.new(:kind, :exchange, :routing_key)

  # enabled: false es el modo de ENABLE_PUBLISHER apagado (ver dry_run)
  def initialize(master:, publisher:, city_id:, log:, enabled: true, peer_routing_key_format: 'city.%s',
                 limiter: RateLimiter.new(limit: MARKET_LIMIT_PER_MINUTE, window: 60))
    @master = master
    @publisher = publisher
    @city_id = city_id
    @log = log
    @enabled = enabled
    @peer_format = peer_routing_key_format
    @limiter = limiter
    @dry_run_logged = {}
  end

  def run_once
    @limited = false
    @held = 0
    @master.pending_outbox.each do |item|
      # si uno no se pudo publicar se corta la vuelta, asi no salen desordenados
      break unless handle(item)
    end
    log_held
  end

  private

  def handle(item)
    id = item['id']
    message = item['payload']
    destination = destination_for(item)
    problem = problem_in(message) || destination_problem(destination)
    return reject(id, message, problem) if problem
    return dry_run(id, message) unless @enabled
    return hold unless quota_for?(destination)

    publish(id, message, destination)
  end

  # exchange y routing_key vacios = a la central, como en la E1. exchange vacio = el de siempre
  def destination_for(item)
    exchange = item['exchange'].to_s
    routing_key = item['routing_key'].to_s
    return Destination.new(:central, nil, nil) if exchange.empty? && routing_key.empty?
    return Destination.new(:market, exchange, routing_key) if exchange == MARKET_EXCHANGE
    return Destination.new(:city, nil, routing_key) if exchange.empty?

    Destination.new(:unknown, exchange, routing_key)
  end

  # al mercado solo podemos publicar nuestra propia oferta: market.offer.TK3 y nada mas
  def destination_problem(destination)
    case destination.kind
    when :market
      own_key = "market.offer.#{@city_id}"
      "al mercado solo se publica con #{own_key}, no con #{destination.routing_key}" if destination.routing_key != own_key
    when :city
      "#{destination.routing_key} no es la routing key de una ciudad" unless peer_routing_key?(destination.routing_key)
    when :unknown
      "no se publica en el exchange #{destination.exchange}"
    end
  end

  # con el formato "city.%s": city.HGW si, central o city. no
  def peer_routing_key?(routing_key)
    prefix, suffix = @peer_format.split('%s', 2)
    code = routing_key.delete_prefix(prefix.to_s).delete_suffix(suffix.to_s)
    code.match?(/\A[\w-]+\z/) && format(@peer_format, code) == routing_key
  end

  # lo de la central no se limita. si al mercado o a otra ciudad se acaba el cupo, ese mensaje y los
  # siguientes de ese tipo esperan a la otra vuelta (asi no salen desordenados), pero la vuelta sigue
  # para que lo de la central no quede atrapado detras
  def quota_for?(destination)
    return true if destination.kind == :central

    @limited ||= !@limiter.take
    !@limited
  end

  def hold
    @held += 1
    true
  end

  # una sola linea por vuelta, no una por mensaje
  def log_held
    return if @held.zero?

    @log.call("Cupo de #{MARKET_LIMIT_PER_MINUTE} por minuto al mercado y a otras ciudades agotado: " \
              "#{@held} pendientes esperan a la otra vuelta.")
  end

  # con ENABLE_PUBLISHER apagado no se llama al broker ni se marca nada: el mensaje SIGUE PENDIENTE
  # (no es enviado ni fallido), asi sale cuando se prenda el interruptor y se reinicie el connector.
  # no es un bucle de reintentos: no se publica nada, y cada pendiente se loguea una sola vez por proceso.
  def dry_run(id, message)
    return true if @dry_run_logged[id]

    @dry_run_logged[id] = true
    @log.call("ENABLE_PUBLISHER apagado, no se publica el pendiente #{id}: " \
              "type=#{message['type']} msgId=#{message['msgId']} idpk=#{message['idpk']} cityId=#{message['cityId']}")
    true
  end

  # mejor no mandarlo que recibir un nack: queda como fallido y no se intenta de nuevo
  def reject(id, message, problem)
    msg_id = message.is_a?(Hash) ? message['msgId'] : nil
    @log.call("Pendiente #{id} (#{msg_id}) NO se publica: #{problem}")
    @master.mark_outbox(id, 'failed', problem)
    true
  end

  # si falla queda pendiente y se intenta en la proxima vuelta
  def publish(id, message, destination)
    confirmed = @publisher.publish_confirmed(message, exchange: destination.exchange,
                                                      routing_key: destination.routing_key)
    unless confirmed
      @log.call("El broker no confirmó #{message['msgId']}, queda pendiente.")
      return false
    end

    @log.call("Publicado #{message['type']} #{message['msgId']} hacia #{destination.routing_key || 'la central'}.")
    mark_sent(id)
    true
  rescue StandardError => e
    @log.call("No se pudo publicar #{message['msgId']} (#{e.class}), queda pendiente.")
    false
  end

  # ojo: si esto falla el mensaje sale de nuevo en la otra vuelta, con el mismo idpk (la central lo toma como repetido)
  def mark_sent(id)
    result = @master.mark_outbox(id, 'sent')
    @log.call("No se pudo marcar como enviado el pendiente #{id}, se va a reenviar.") unless result.saved?
  end

  def problem_in(message)
    return 'el mensaje no es un objeto' unless message.is_a?(Hash)

    missing = REQUIRED_FIELDS.find { |field| !MessageValidator.text?(message[field]) }
    return "falta el campo #{missing}" if missing
    return 'msgId e idpk son iguales' if message['msgId'] == message['idpk']
    return "cityId es #{message['cityId'].inspect} y deberia ser #{@city_id}" unless message['cityId'] == @city_id

    nil
  end
end
