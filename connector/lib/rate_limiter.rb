# cuenta publicaciones en una ventana deslizante: a lo sumo `limit` en los ultimos `window` segundos.
# la central permite 60 operaciones de mercado por minuto; el outbox usa menos para tener margen.
class RateLimiter
  def initialize(limit:, window:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @limit = limit
    @window = window
    @clock = clock
    @times = []
  end

  # true si queda cupo, y en ese caso lo ocupa
  def take
    now = @clock.call
    @times.shift while @times.any? && now - @times.first >= @window
    return false if @times.size >= @limit

    @times << now
    true
  end
end
