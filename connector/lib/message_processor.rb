require_relative 'message_validator'

# decide que hacer con cada mensaje. process devuelve:
#   :done   listo, ack en la cola
#   :retry  devolverlo a la cola (la pausa ya se hizo aca)
#   :reject se agotaron los reintentos, sacarlo de la cola sin requeue
class MessageProcessor
  REJECTION_TYPES = %w[nack error].freeze
  # pausa antes de cada reintento. son 3 reintentos: al cuarto fallo se rechaza
  RETRY_DELAYS = [5, 15, 45].freeze
  # tope para que el hash no crezca si un mensaje con fallos nunca vuelve (ej: lo borraron de la cola)
  MAX_TRACKED = 1000

  def initialize(master:, publisher:, log: ->(text) { puts "[Connector] #{text}" }, sleeper: ->(s) { sleep s })
    @master = master
    @publisher = publisher
    @log = log
    @sleeper = sleeper
    # fallos por msgId. en memoria: con prefetch(1) el requeue vuelve altiro a este mismo consumer
    @failures = {}
  end

  def process(raw_body)
    decision = validate(raw_body)
    key = retry_key(decision, raw_body)
    outcome = handle(decision, raw_body)
    return retry_or_give_up(decision, key) if outcome == :retry

    @failures.delete(key)
    outcome
  end

  private

  def handle(decision, raw_body)
    case decision.action
    when :discard then discard(decision, raw_body)
    when :nack    then reject(decision)
    else               deliver(decision)
    end
  rescue StandardError => e
    # si falla algo raro (ej: no se pudo publicar la respuesta) mejor reintentar que perder el mensaje
    @log.call("Error inesperado: #{e.class}: #{e.message}")
    :retry
  end

  def retry_key(decision, raw_body)
    message = decision.message
    message.is_a?(Hash) && message['msgId'].is_a?(String) ? message['msgId'] : raw_body.to_s
  end

  def retry_or_give_up(decision, key)
    failures = (@failures.delete(key) || 0) + 1
    return give_up(decision, failures) if failures > RETRY_DELAYS.size

    @failures[key] = failures
    @failures.shift while @failures.size > MAX_TRACKED
    delay = RETRY_DELAYS[failures - 1]
    @log.call("Reintento #{failures}/#{RETRY_DELAYS.size} de #{key} en #{delay}s.")
    @sleeper.call(delay)
    :retry
  end

  # mensaje venenoso o API caida mucho rato: se saca de la cola para no trabarla (prefetch 1)
  # y queda registrado en la API. a la central no se le publica nada: el enunciado no tiene un
  # NACK para esto (solo MALFORMED_MESSAGE, UNKNOWN_TYPE, IDPK_EQUALS_MSGID e IDENTITY_MISMATCH)
  def give_up(decision, failures)
    message = decision.message
    @log.call("Se rechaza #{message.is_a?(Hash) ? message['msgId'] : 'mensaje'}: " \
              "no se pudo procesar tras #{failures} intentos.")
    # discard y no nack: en la API un NACK significa que se lo mandamos a la central
    report('discard', message, 'MAX_RETRIES_EXCEEDED')
    :reject
  end

  # si el validador se cae se descarta. reintentarlo seria fallar igual para siempre y trabar la cola
  def validate(raw_body)
    MessageValidator.check(raw_body)
  rescue StandardError => e
    MessageValidator.discard("el validador falló (#{e.class})")
  end

  def discard(decision, raw_body)
    @log.call("Descartado: #{decision.detail}")
    # una respuesta de la central invalida igual se registra como CENTRAL_<tipo>, nunca se responde
    if reply?(decision.message)
      report('central', decision.message, decision.detail)
    else
      # va como texto porque la API lo guarda tal cual llego
      report('discard', readable(raw_body), decision.detail)
    end
    :done
  end

  def reply?(message)
    message.is_a?(Hash) && MessageValidator::REPLY_TYPES.include?(message['type'])
  end

  # nack y listo, no se reintenta porque va a seguir igual de malo
  def reject(decision)
    message = decision.message
    @log.call("Nack #{decision.reason} a #{message['msgId']}: #{decision.detail}")
    @publisher.nack(message, decision.reason, decision.code, decision.detail)
    report('nack', message, decision.reason)
    :done
  end

  def deliver(decision)
    message = decision.message
    log_rejection(message) if REJECTION_TYPES.include?(message['type'])
    result = @master.deliver(message)

    if result.saved?
      # ojo: primero guardar y despues el ack, si no podemos perder el mensaje
      @publisher.ack(message) if decision.send_ack
      @log.call("Mensaje #{message['msgId']} (#{message['type']}) guardado.")
      :done
    elsif result.invalid?
      reject_by_master(decision, result)
    else
      @log.call("La API no guardó #{message['msgId']} (#{result.status || 'sin respuesta'}).")
      :retry
    end
  end

  # la API responde 422 con error MALFORMED_MESSAGE o UNKNOWN_TYPE; el NACK usa el code del enunciado
  def reject_by_master(decision, result)
    message = decision.message
    @log.call("La API rechazó #{message['msgId']}: #{result.reason}")
    reason, code = result.error_code == 'UNKNOWN_TYPE' ? ['UNKNOWN_TYPE', 400] : ['MALFORMED_MESSAGE', 422]
    # los ack/nack/error de la central no se responden nunca
    @publisher.nack(message, reason, code, result.reason) if decision.send_ack
    :done
  end

  # solo se deja en el log, no se reenvia nada: el mismo mensaje volveria a fallar
  def log_rejection(message)
    target = message['data'].is_a?(Hash) ? message['data']['target'] : nil
    text = "La central rechazó #{target} con #{message['type']}: #{message['reason']} (#{message['code']})."
    text += ' Revisar RABBITMQ_USER y CITY_ID.' if message['reason'] == 'IDENTITY_MISMATCH'
    @log.call(text)
  end

  # si el aviso falla da lo mismo, se loguea y se sigue
  def report(kind, raw, reason)
    result = @master.report_rejected(kind: kind, raw: raw, reason: reason)
    @log.call("No se pudo avisar el rechazo a la API (#{result.status || result.body}).") unless result.saved?
  rescue StandardError => e
    @log.call("No se pudo avisar el rechazo a la API (#{e.class}).")
  end

  # los bytes malos y el byte nulo se cambian por ? (postgres no acepta el nulo en un json)
  def readable(raw_body)
    raw_body.to_s.dup.force_encoding('UTF-8').scrub('?').tr("\u0000", '?')
  end
end
