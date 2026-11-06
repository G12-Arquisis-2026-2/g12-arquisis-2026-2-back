require 'bunny'
require 'fileutils'
require_relative 'lib/central_publisher'
require_relative 'lib/master_client'
require_relative 'lib/message_processor'
require_relative 'lib/offer_memory'
require_relative 'lib/outbox_sender'

# esto para que no los logs no tengar atraso.
$stdout.sync = true

RETRY_SECONDS = 5
OUTBOX_SECONDS = 2
MAX_SECONDS_OFFLINE = 120
ALIVE_FILE = '/tmp/connector_alive'.freeze
# apagado por defecto: solo publica hacia la central si ENABLE_PUBLISHER es exactamente "true"
PUBLISHER_ENABLED = ENV.fetch('ENABLE_PUBLISHER', 'false') == 'true'
# routing key para responderle a otra ciudad: city.{CODE} (contratos v3.0.2, tabla "Mensajes AMQP")
PEER_ROUTING_KEY_FORMAT = ENV.fetch('PEER_ROUTING_KEY_FORMAT', 'city.%s')

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

# la pausa entre reintentos (5s, 15s, 45s) la hace el processor antes de devolver :retry.
# ojo: esto es el ack AL BROKER (sacar el mensaje de la cola). el mensaje "ack" del protocolo,
# el que se le manda a la central o a otra ciudad, lo publica el processor
def settle(channel, delivery_tag, outcome)
  case outcome
  when :done   then channel.ack(delivery_tag)
  when :reject then channel.nack(delivery_tag, false, false) # sin requeue: se agotaron los reintentos
  else              channel.nack(delivery_tag, false, true)
  end
rescue StandardError => e
  # si el canal se cortó el broker reentrega el mensaje por su cuenta.
  log "No se pudo confirmar al broker (#{e.class})."
end

def central_publisher(channel, open_channel: nil)
  CentralPublisher.new(
    channel,
    exchange: ENV.fetch('RABBITMQ_EXCHANGE'),
    routing_key: ENV.fetch('CENTRAL_ROUTING_KEY'),
    user_id: ENV.fetch('RABBITMQ_USER'),
    city_id: ENV.fetch('CITY_ID'),
    peer_routing_key_format: PEER_ROUTING_KEY_FORMAT,
    enabled: PUBLISHER_ENABLED,
    log: method(:log),
    open_channel: open_channel
  )
end

# un canal por cola: prefetch 1, un mensaje a la vez, no se pide otro hasta resolver el actual
def consumer_channel(connection)
  channel = connection.create_channel
  channel.prefetch(1)
  channel
end

# passive porque no tenemos permiso para crear la cola.
# sin block: true. si se corta la red bunny reconecta solo y vuelve a suscribir este consumidor
def subscribe(channel, queue_name, processor)
  queue = channel.queue(queue_name, passive: true)
  queue.subscribe(manual_ack: true) do |delivery, properties, body|
    outcome = processor.process(body, properties.user_id, delivery.routing_key)
    settle(channel, delivery.delivery_tag, outcome)
  end
  log "Escuchando en '#{queue_name}'..."
end

# si la cola del mercado no existe o no tenemos permiso, se sigue solo con la de la ciudad:
# caerse aca dejaria sin responder tambien a la central. el canal queda cerrado y fuera de la vigilancia
def subscribe_market(connection, master)
  channel = consumer_channel(connection)
  # nil: en la cola del mercado nunca se publica una respuesta
  processor = MessageProcessor.new(master: master, publisher: nil, queue: :market)
  subscribe(channel, ENV.fetch('MARKET_QUEUE_NAME', "market.#{ENV.fetch('CITY_ID')}"), processor)
  channel
rescue Bunny::NotFound, Bunny::AccessRefused => e
  log "OJO: no se pudo abrir la cola del mercado (#{e.class}). Se sigue solo con la cola de la ciudad."
  nil
end

# canal aparte para el hilo que publica: en bunny un canal no se puede compartir entre hilos
def outbox_channel(connection)
  channel = connection.create_channel
  channel.confirm_select
  channel
end

# cada 2 segundos publica lo que la API dejo pendiente. si algo falla se loguea y se sigue en la otra vuelta
def start_outbox_thread(sender, connection)
  Thread.new do
    loop do
      begin
        # sin conexion ni se intenta, asi no se llena el log mientras el broker esta caido
        sender.run_once if connection.open?
      rescue StandardError => e
        log "Error publicando pendientes (#{e.class}: #{e.message})."
      end
      sleep OUTBOX_SECONDS
    end
  end
end

log 'ENABLE_PUBLISHER apagado: no se publica nada hacia la central, solo se loguea.' unless PUBLISHER_ENABLED

unless ENV.fetch('RABBITMQ_USER') == "city.#{ENV.fetch('CITY_ID')}"
  log "OJO: RABBITMQ_USER no es city.#{ENV.fetch('CITY_ID')}, la central va a rechazar lo que publiquemos."
end

connection = connect(ENV.fetch('RABBITMQ_URL'))
master = MasterClient.new(ENV.fetch('MASTER_URL'))
# nuestra oferta vigente y el ultimo status-statement, para republicarla tras un corte
offers = OfferMemory.new

# city.TK3: central, otras ciudades y wallet. aca si se responde ack/nack
city_channel = consumer_channel(connection)
city_processor = MessageProcessor.new(master: master, publisher: central_publisher(city_channel), offers: offers)
subscribe(city_channel, ENV.fetch('QUEUE_NAME'), city_processor)

# market.TK3: canal y consumidor propios, misma politica de reintentos
market_channel = subscribe_market(connection, master)

outbox_publisher = central_publisher(outbox_channel(connection), open_channel: -> { outbox_channel(connection) })
sender = OutboxSender.new(master: master, publisher: outbox_publisher,
                          city_id: ENV.fetch('CITY_ID'), log: method(:log), enabled: PUBLISHER_ENABLED,
                          peer_routing_key_format: PEER_ROUTING_KEY_FORMAT, offers: offers)
start_outbox_thread(sender, connection)

# bunny ya reabrio los canales y volvio a suscribir los consumidores
connection.after_recovery_completed do
  log 'Bunny recuperó la conexión y los consumidores.'
  sender.connection_recovered!
end

# solo los canales de consumo: si el broker cierra el del outbox, el hilo del outbox abre otro
channels = [city_channel, market_channel].compact

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
