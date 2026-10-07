require 'bunny'
require 'fileutils'
require_relative 'lib/central_publisher'
require_relative 'lib/master_client'
require_relative 'lib/message_processor'

# esto para que no los logs no tengar atraso.
$stdout.sync = true

RETRY_SECONDS = 5
MAX_SECONDS_OFFLINE = 120
ALIVE_FILE = '/tmp/connector_alive'.freeze

def log(text)
  puts "[Connector] #{text}"
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def connect(url)
  # verify_peer en true porque bunny con una URL no revisa el certificado del broker, y hay que revisarlo
  connection = Bunny.new(url, verify_peer: true, tls_silence_warnings: true,
                              automatically_recover: true, network_recovery_interval: RETRY_SECONDS)
  connection.start
  connection
rescue StandardError => e
  # ojo: no imprimir e.message, puede traer la URL con la clave
  log "No se pudo conectar al broker (#{e.class}). Reintentando en #{RETRY_SECONDS}s..."
  sleep RETRY_SECONDS
  retry
end

def settle(channel, delivery_tag, outcome)
  if outcome == :done
    channel.ack(delivery_tag)
  else
    # la pausa es para no quedar en un loop rapido de reintentos mientras la API esta caida
    sleep RETRY_SECONDS
    channel.nack(delivery_tag, false, true)
  end
rescue StandardError => e
  # si el canal se cortó el broker reentrega el mensaje por su cuenta.
  log "No se pudo confirmar al broker (#{e.class})."
end

connection = connect(ENV.fetch('RABBITMQ_URL'))
channel = connection.create_channel
channel.prefetch(1) # un mensaje a la vez, no se pide otro hasta resolver el actual

publisher = CentralPublisher.new(
  channel,
  exchange: ENV.fetch('RABBITMQ_EXCHANGE'),
  routing_key: ENV.fetch('CENTRAL_ROUTING_KEY'),
  user_id: ENV.fetch('RABBITMQ_USER'),
  city_id: ENV.fetch('CITY_ID')
)
processor = MessageProcessor.new(master: MasterClient.new(ENV.fetch('MASTER_URL')), publisher: publisher)

queue_name = ENV.fetch('QUEUE_NAME')
# passive porque no tenemos permiso para crear la cola
queue = channel.queue(queue_name, passive: true)

# sin block: true. si se corta la red bunny reconecta solo, con block terminabamos abriendo 2 conexiones
queue.subscribe(manual_ack: true) do |delivery, _properties, body|
  settle(channel, delivery.delivery_tag, processor.process(body))
end
log "Escuchando en '#{queue_name}'..."

offline_since = nil
channel_was_closed = false

loop do
  sleep RETRY_SECONDS

  if connection.open?
    offline_since = nil
    if channel.open?
      channel_was_closed = false
      FileUtils.touch(ALIVE_FILE) # lo revisa el HEALTHCHECK del Dockerfile
    else
      # se espera a verlo cerrado 2 veces, al reconectar el canal vuelve un poco despues que la conexion
      if channel_was_closed
        log 'El canal quedó cerrado con la conexión abierta. Saliendo.'
        # exit(1) para que docker reinicie el contenedor y parta con una conexion limpia
        exit(1)
      end
      channel_was_closed = true
    end
  else
    offline_since ||= now
    if now - offline_since > MAX_SECONDS_OFFLINE
      log "Más de #{MAX_SECONDS_OFFLINE}s sin conexión al broker. Saliendo."
      exit(1)
    end
  end
end
