require_relative 'message_validator'

# decide que hacer con cada mensaje. process devuelve :done (listo) o :retry (hay que devolverlo a la cola)
class MessageProcessor
  REJECTION_TYPES = %w[nack error].freeze

  def initialize(master:, publisher:, log: ->(text) { puts "[Connector] #{text}" })
    @master = master
    @publisher = publisher
    @log = log
  end

  def process(raw_body)
    decision = validate(raw_body)

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

  private

  # si el validador se cae se descarta. reintentarlo seria fallar igual para siempre y trabar la cola
  def validate(raw_body)
    MessageValidator.check(raw_body)
  rescue StandardError => e
    MessageValidator.discard("el validador falló (#{e.class})")
  end

  def discard(decision, raw_body)
    @log.call("Descartado: #{decision.detail}")
    # va como texto porque la API lo guarda tal cual llego
    report('discard', readable(raw_body), decision.detail)
    :done
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
      reject_by_master(decision, result.reason)
    else
      @log.call("La API no guardó #{message['msgId']} (#{result.status || 'sin respuesta'}).")
      :retry
    end
  end

  def reject_by_master(decision, reason)
    message = decision.message
    @log.call("La API rechazó #{message['msgId']}: #{reason}")
    # los ack/nack/error de la central no se responden nunca
    @publisher.nack(message, 'MALFORMED_MESSAGE', 422, reason) if decision.send_ack
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
