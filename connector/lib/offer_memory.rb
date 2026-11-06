require 'time'

# recuerda en memoria nuestra ultima oferta publicada al mercado y el ultimo status-statement,
# para republicar la oferta vigente despues de un corte del broker (anomalia 5).
# si el proceso se reinicia, esta memoria se pierde.
# la usan tres hilos (city.TK3, el del outbox y el de la recuperacion de bunny), por eso el mutex
class OfferMemory
  OFFER_TYPES = %w[offer offer-updated].freeze

  # message: la oferta tal como salio. exchange y routing_key: a donde se publico
  Offer = Struct.new(:message, :exchange, :routing_key)

  def initialize
    @mutex = Mutex.new
    @offer = nil
    @cycle_id = nil
    @last_offer_at = nil
  end

  def status_received(message)
    return unless message['type'] == 'status-statement'

    @mutex.synchronize do
      @cycle_id = message['cycleId']
      @last_offer_at = message.dig('data', 'market', 'lastOfferAt')
    end
  end

  def offer_published(message, exchange, routing_key)
    @mutex.synchronize do
      if OFFER_TYPES.include?(message['type'])
        @offer = Offer.new(message, exchange, routing_key)
      elsif message['type'] == 'offer-withdrawn' && same_offer?(message)
        @offer = nil
      end
    end
  end

  # la oferta recordada si es del ciclo actual y todavia no pasa lastOfferAt; si no, nil
  def offer_to_republish(now = Time.now)
    @mutex.synchronize do
      return nil unless @offer && @offer.message['cycleId'] == @cycle_id && before_last_offer?(now)

      @offer
    end
  end

  private

  def same_offer?(message)
    @offer && @offer.message.dig('data', 'offerId') == message.dig('data', 'offerId')
  end

  def before_last_offer?(now)
    @last_offer_at && now < Time.iso8601(@last_offer_at)
  rescue ArgumentError
    false
  end
end
