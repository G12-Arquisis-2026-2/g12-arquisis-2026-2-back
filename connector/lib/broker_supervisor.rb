# vigila la conexion al broker cada 5 s (la llama el hilo principal de consumer.rb).
# sin broker el connector NO termina: sigue reintentando para siempre. si bunny deja de recuperarse solo,
# cierra esa conexion y abre una nueva. exit(1) queda solo para el canal de city cerrado por el broker
class BrokerSupervisor
  OFFLINE_LOG_SECONDS = 60
  MARKET_RETRY_SECONDS = 30
  MARKET_LOG_SECONDS = 300

  attr_reader :session

  # open_session: -> { BrokerSession } (lanza error si no se puede conectar)
  # on_new_session: ->(session) {} cada vez que se abre una sesion nueva (el outbox reabre su canal)
  # alive: -> {} marca el HEALTHCHECK. exit_process: ->(code) {}
  def initialize(open_session:, log:, alive:, exit_process:, on_new_session: ->(_) {},
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @open_session = open_session
    @on_new_session = on_new_session
    @log = log
    @alive = alive
    @exit_process = exit_process
    @clock = clock
    @session = nil
  end

  def connected?
    !@session.nil? && @session.open?
  end

  def tick(now = @clock.call)
    drop_abandoned if @session
    @session ||= open_session(now)
    connected? ? online(now) : offline(now)
  end

  private

  # se espera a verla abandonada dos vueltas seguidas: bunny marca la falla un poco antes de empezar a recuperar
  def drop_abandoned
    return @abandoned_seen = false unless @session.abandoned?
    return @abandoned_seen = true unless @abandoned_seen

    @log.call('Bunny dejó de reintentar la conexión: se cierra y se abre una nueva.')
    @session.close
    @session = nil
    @abandoned_seen = false
  end

  def open_session(now)
    session = @open_session.call
    @log.call('Conectado al broker.')
    @market_tried_at = now
    @on_new_session.call(session)
    session
  rescue StandardError => e
    # ojo: no imprimir e.message, puede traer la URL con la clave
    @log.call("No se pudo conectar al broker (#{e.class}).") unless @offline_since
    nil
  end

  def online(now)
    back_online(now) if @offline_since
    retry_market(now) unless @session.market?
    return city_closed unless @session.city_open?

    @city_closed_seen = false
    @alive.call
  end

  def back_online(now)
    @log.call("Conexión con el broker recuperada tras #{seconds(now - @offline_since)} s.")
    @offline_since = nil
  end

  # sin el archivo del HEALTHCHECK al dia docker lo marca unhealthy, pero el proceso sigue
  def offline(now)
    return start_offline(now) unless @offline_since
    return if now - @offline_logged_at < OFFLINE_LOG_SECONDS

    @offline_logged_at = now
    @log.call("Sin conexión con el broker hace #{seconds(now - @offline_since)} s, reintentando.")
  end

  def start_offline(now)
    @offline_since = now
    @offline_logged_at = now
    @log.call('Sin conexión con el broker. Se reintenta cada 5 s, sin terminar el proceso.')
  end

  # la cola de la ciudad sigue igual mientras tanto
  def retry_market(now)
    return if @market_tried_at && now - @market_tried_at < MARKET_RETRY_SECONDS

    @market_tried_at = now
    return market_subscribed if @session.retry_market
    return if @market_logged_at && now - @market_logged_at < MARKET_LOG_SECONDS

    @market_logged_at = now
    @log.call("Sin la cola del mercado: se reintenta cada #{MARKET_RETRY_SECONDS} s.")
  end

  def market_subscribed
    @market_logged_at = nil
    @log.call('Suscrito a la cola del mercado.')
  end

  # con la conexion abierta, un canal de city cerrado lo cerro el broker (cola borrada, sin permiso):
  # reconectar no lo arregla. se espera a verlo cerrado 2 veces, al recuperarse el canal vuelve despues
  def city_closed
    return @city_closed_seen = true unless @city_closed_seen

    @log.call('El canal de la cola de la ciudad quedó cerrado con la conexión abierta. Saliendo.')
    @exit_process.call(1)
  end

  def seconds(value)
    value.round
  end
end
