require 'bunny'
require 'fileutils'
require 'socket'
require_relative 'lib/broker_session'
require_relative 'lib/broker_supervisor'
require_relative 'lib/central_publisher'
require_relative 'lib/master_client'
require_relative 'lib/message_processor'
require_relative 'lib/outbox_sender'
require_relative 'lib/saga_starter'

# esto para que no los logs no tengar atraso.
$stdout.sync = true

RETRY_SECONDS = 5
OUTBOX_SECONDS = 2
ALIVE_FILE = '/tmp/connector_alive'.freeze
# apagado por defecto: solo publica hacia la central si ENABLE_PUBLISHER es exactamente "true"
PUBLISHER_ENABLED = ENV.fetch('ENABLE_PUBLISHER', 'false') == 'true'
# apagado por defecto: con "true" el relay reserva las filas (POST /events/outbox/claim) en vez del GET (ADR8)
OUTBOX_CLAIM_ENABLED = ENV.fetch('OUTBOX_CLAIM_ENABLED', 'false') == 'true'
# apagado por defecto: con "true" el relay inicia las sagas (StartExecution) de las filas step_functions (ADR8)
SAGA_START_ENABLED = ENV.fetch('SAGA_START_ENABLED', 'false') == 'true'
# routing key para responderle a otra ciudad: city.{CODE} (contratos v3.0.2, tabla "Mensajes AMQP")
PEER_ROUTING_KEY_FORMAT = ENV.fetch('PEER_ROUTING_KEY_FORMAT', 'city.%s')

def log(text)
  puts "[Connector] #{text}"
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# un solo intento: si falla, el supervisor vuelve a intentar en 5 s
def connect(url)
  # verify_peer en true porque bunny con una URL no revisa el certificado del broker, y hay que revisarlo
  # heartbeat de 10s para darse cuenta rapido de un corte de red silencioso (si no, pasan mas de 2 minutos)
  connection = Bunny.new(url, verify_peer: true, tls_silence_warnings: true, heartbeat: 10,
                              automatically_recover: true, network_recovery_interval: RETRY_SECONDS)
  connection.start
  connection
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

# si la cola del mercado no existe o no tenemos permiso, se sigue solo con la de la ciudad y el supervisor
# lo reintenta cada 30 s: caerse aca dejaria sin responder tambien a la central
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
def start_outbox_thread(sender, supervisor)
  Thread.new do
    loop do
      begin
        # sin conexion ni se intenta, asi no se llena el log mientras el broker esta caido
        sender.run_once if supervisor.connected?
      rescue StandardError => e
        log "Error publicando pendientes (#{e.class}: #{e.message})."
      end
      sleep OUTBOX_SECONDS
    end
  end
end

# conexion nueva con los consumidores de las dos colas. bunny la recupera sola tras un corte; si se rinde,
# el supervisor llama de nuevo a esto
def open_session(master, sender)
  connection = connect(ENV.fetch('RABBITMQ_URL'))
  # bunny ya reabrio los canales y volvio a suscribir los consumidores
  connection.after_recovery_completed do
    log 'Bunny recuperó la conexión y los consumidores.'
    sender.connection_recovered!
  end
  BrokerSession.new(
    connection,
    # city.TK3: central, otras ciudades y wallet. aca si se responde ack/nack
    subscribe_city: lambda { |conn|
      channel = consumer_channel(conn)
      subscribe(channel, ENV.fetch('QUEUE_NAME'), MessageProcessor.new(master: master, publisher: central_publisher(channel)))
      channel
    },
    # market.TK3: canal y consumidor propios, misma politica de reintentos
    subscribe_market: ->(conn) { subscribe_market(conn, master) }
  )
rescue StandardError
  # ej: la cola de la ciudad no existe. sin cerrarla quedaria una conexion abierta por cada reintento
  BrokerSession.close_quietly(connection) if connection
  raise
end

log 'ENABLE_PUBLISHER apagado: no se publica nada hacia la central, solo se loguea.' unless PUBLISHER_ENABLED

unless ENV.fetch('RABBITMQ_USER') == "city.#{ENV.fetch('CITY_ID')}"
  log "OJO: RABBITMQ_USER no es city.#{ENV.fetch('CITY_ID')}, la central va a rechazar lo que publiquemos."
end

master = MasterClient.new(ENV.fetch('MASTER_URL'))

# credenciales: la cadena por omision del SDK, que en la EC2 toma las del rol (IMDSv2). no se pasan llaves
def saga_client
  require 'aws-sdk-states'
  log 'OJO: hay AWS_ACCESS_KEY_ID en el entorno; las sagas deberían usar el rol de la EC2.' if ENV['AWS_ACCESS_KEY_ID']
  Aws::States::Client.new(region: ENV.fetch('AWS_REGION'))
end

sagas = SagaStarter.new(client: SAGA_START_ENABLED ? saga_client : nil, log: method(:log), enabled: SAGA_START_ENABLED,
                        arns: { 'seller' => ENV['SAGA_SELLER_ARN'], 'buyer' => ENV['SAGA_BUYER_ARN'] })
log 'SAGA_START_ENABLED apagado: las sagas quedan pendientes en el outbox.' unless SAGA_START_ENABLED
supervisor = nil
# sin canal al partir: el hilo del outbox lo abre en la conexion vigente (connection_replaced!)
outbox_publisher = central_publisher(nil, open_channel: -> { outbox_channel(supervisor.session.connection) })
sender = OutboxSender.new(master: master, publisher: outbox_publisher,
                          city_id: ENV.fetch('CITY_ID'), log: method(:log), enabled: PUBLISHER_ENABLED,
                          peer_routing_key_format: PEER_ROUTING_KEY_FORMAT,
                          claim_as: OUTBOX_CLAIM_ENABLED ? "connector-#{Socket.gethostname}" : nil,
                          sagas: sagas)

supervisor = BrokerSupervisor.new(
  open_session: -> { open_session(master, sender) },
  # tambien en el primer arranque: abre el canal del outbox y republica la oferta vigente
  on_new_session: ->(_session) { sender.connection_replaced! },
  log: method(:log),
  alive: -> { FileUtils.touch(ALIVE_FILE) }, # lo revisa el HEALTHCHECK del Dockerfile
  exit_process: ->(code) { exit(code) }
)
start_outbox_thread(sender, supervisor)

loop do
  supervisor.tick
  sleep RETRY_SECONDS
end
