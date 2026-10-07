require 'bunny'
require 'fileutils'
require_relative 'lib/central_publisher'
require_relative 'lib/master_client'
require_relative 'lib/message_processor'
require_relative 'lib/outbox_sender'

# esto para que no los logs no tengar atraso.
$stdout.sync = true

RETRY_SECONDS = 5
OUTBOX_SECONDS = 2
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
  # heartbeat de 10s para darse cuenta rapido de un corte de red silencioso (si no, pasan mas de 2 minutos)
  connection = Bunny.new(url, verify_peer: true, tls_silence_warnings: true, heartbeat: 10,
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

def central_publisher(channel)
  CentralPublisher.new(
    channel,
    exchange: ENV.fetch('RABBITMQ_EXCHANGE'),
    routing_key: ENV.fetch('CENTRAL_ROUTING_KEY'),
    user_id: ENV.fetch('RABBITMQ_USER'),
    city_id: ENV.fetch('CITY_ID')
  )
end

# cada 2 segundos publica lo que la API dejo pendiente. si algo falla se loguea y se sigue en la otra vuelta
def start_outbox_thread(sender, connection, channel)
  Thread.new do
    loop do
      begin
        # sin conexion ni se intenta, asi no se llena el log mientras el broker esta caido
        sender.run_once if connection.open? && channel.open?
      rescue StandardError => e
        log "Error publicando pendientes (#{e.class}: #{e.message})."
      end
      sleep OUTBOX_SECONDS
    end
  end
end

unless ENV.fetch('RABBITMQ_USER') == "city.#{ENV.fetch('CITY_ID')}"
  log "OJO: RABBITMQ_USER no es city.#{ENV.fetch('CITY_ID')}, la central va a rechazar lo que publiquemos."
end

connection = connect(ENV.fetch('RABBITMQ_URL'))
channel = connection.create_channel
channel.prefetch(1) # un mensaje a la vez, no se pide otro hasta resolver el actual

master = MasterClient.new(ENV.fetch('MASTER_URL'))
processor = MessageProcessor.new(master: master, publisher: central_publisher(channel))

queue_name = ENV.fetch('QUEUE_NAME')
# passive porque no tenemos permiso para crear la cola
queue = channel.queue(queue_name, passive: true)

# sin block: true. si se corta la red bunny reconecta solo, con block terminabamos abriendo 2 conexiones
queue.subscribe(manual_ack: true) do |delivery, _properties, body|
  settle(channel, delivery.delivery_tag, processor.process(body))
end
log "Escuchando en '#{queue_name}'..."

# canal aparte para el hilo que publica: en bunny un canal no se puede compartir entre hilos
outbox_channel = connection.create_channel
outbox_channel.confirm_select
sender = OutboxSender.new(master: master, publisher: central_publisher(outbox_channel),
                          city_id: ENV.fetch('CITY_ID'), log: method(:log))
start_outbox_thread(sender, connection, outbox_channel)
channels = [channel, outbox_channel]

offline_since = nil
channel_was_closed = false
connected = true

loop do
  sleep RETRY_SECONDS

  if connection.open?
    log 'Conexión con el broker recuperada.' unless connected
    connected = true
    offline_since = nil
    if channels.all?(&:open?)
      channel_was_closed = false
      FileUtils.touch(ALIVE_FILE) # lo revisa el HEALTHCHECK del Dockerfile
    else
      # se espera a verlo cerrado 2 veces, al reconectar el canal vuelve un poco despues que la conexion
      if channel_was_closed
        log 'Un canal quedó cerrado con la conexión abierta. Saliendo.'
        # exit(1) para que docker reinicie el contenedor y parta con una conexion limpia
        exit(1)
      end
      channel_was_closed = true
    end
  else
    log 'Se perdió la conexión con el broker. Bunny reconecta solo.' if connected
    connected = false
    offline_since ||= now
    if now - offline_since > MAX_SECONDS_OFFLINE
      log "Más de #{MAX_SECONDS_OFFLINE}s sin conexión al broker. Saliendo."
      exit(1)
    end
  end
end
