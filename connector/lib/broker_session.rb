require 'timeout'

# una conexion al broker con los consumidores que cuelgan de ella (city y market).
# si bunny no logra recuperarla, el supervisor la cierra y arma otra nueva
class BrokerSession
  CLOSE_TIMEOUT = 5

  attr_reader :connection

  # subscribe_city / subscribe_market: ->(connection) { canal ya suscrito }.
  # subscribe_market devuelve nil si la cola no existe o no tenemos permiso
  def initialize(connection, subscribe_city:, subscribe_market:)
    @connection = connection
    @subscribe_market = subscribe_market
    @city_channel = subscribe_city.call(connection)
    retry_market
  end

  def open?
    @connection.open?
  end

  # sin conexion y sin recuperacion en curso: bunny se rindio o fallo al reconectar y ya no lo intenta.
  # recovering_from_network_failure? es @private en bunny 2.24, pero es lo unico que dice si sigue intentando
  def abandoned?
    !@connection.open? && !@connection.recovering_from_network_failure?
  end

  def city_open?
    @city_channel.open?
  end

  def market?
    !@market_channel.nil? && @market_channel.open?
  end

  # true si quedo suscrita
  def retry_market
    @market_channel = @subscribe_market.call(@connection)
    market?
  end

  def close
    self.class.close_quietly(@connection)
  end

  # cerrar tambien espera al broker: con tope, para no colgar la vigilancia
  def self.close_quietly(connection)
    Timeout.timeout(CLOSE_TIMEOUT) { connection.close }
  rescue StandardError
    nil
  end
end
