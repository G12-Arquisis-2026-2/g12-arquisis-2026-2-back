require_relative 'message_validator'

# publica hacia la central los mensajes que la API dejo pendientes (outbox)
class OutboxSender
  REQUIRED_FIELDS = %w[msgId idpk type timestamp].freeze

  def initialize(master:, publisher:, city_id:, log:)
    @master = master
    @publisher = publisher
    @city_id = city_id
    @log = log
  end

  def run_once
    @master.pending_outbox.each do |item|
      # si uno no se pudo publicar se corta la vuelta, asi no salen desordenados
      break unless handle(item['id'], item['payload'])
    end
  end

  private

  def handle(id, message)
    problem = problem_in(message)
    return reject(id, message, problem) if problem

    publish(id, message)
  end

  # mejor no mandarlo que recibir un nack: queda como fallido y no se intenta de nuevo
  def reject(id, message, problem)
    msg_id = message.is_a?(Hash) ? message['msgId'] : nil
    @log.call("Pendiente #{id} (#{msg_id}) NO se publica: #{problem}")
    @master.mark_outbox(id, 'failed', problem)
    true
  end

  # si falla queda pendiente y se intenta en la proxima vuelta
  def publish(id, message)
    unless @publisher.publish_confirmed(message)
      @log.call("El broker no confirmó #{message['msgId']}, queda pendiente.")
      return false
    end

    @log.call("Publicado #{message['type']} #{message['msgId']} hacia la central.")
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
