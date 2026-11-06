require 'json'

# mensajes de ejemplo para los tests, tomados de los ejemplos oficiales del curso
# (test/fixtures/contracts-v3.0.2). asi los tests parten de un mensaje que el contrato da por valido
module Samples
  ROOT = File.expand_path('../fixtures/contracts-v3.0.2/amqp', __dir__)

  FILES = {
    'status-statement' => 'sellable-positive', 'transfer' => 'funding', 'distance-table' => 'enabled-routes',
    'trade-recorded' => 'route-enabled', 'imbalance-settlement' => 'coverage-positive',
    'swap-proposed' => 'published-example', 'swap-settled' => 'settled', 'swap-cancelled' => 'cancelled',
    'swap-expired' => 'expired', 'swap-rejected' => 'insufficient-asset-accept',
    'bid' => 'published-example', 'bid-accepted' => 'published-example', 'bid-rejected' => 'quantity-unavailable',
    'ack' => 'central', 'nack' => 'central-malformed-message', 'error' => 'cycle-expired',
    'offer' => 'published-example', 'offer-updated' => 'published-example',
    'offer-withdrawn' => 'published-example', 'market-closed' => 'closed'
  }.freeze

  # copia nueva cada vez, con los cambios pedidos encima
  def self.message(type, changes = {})
    JSON.parse(File.read(File.join(ROOT, type, 'valid', "#{FILES.fetch(type)}.json"))).merge(changes)
  end

  # el user_id con que lo publicaria su emisor real
  def self.user_for(message)
    return "city.#{message['cityId']}" if message['cityId']

    message['type'] == 'market-closed' ? nil : 'central'
  end

  # la routing key con que el broker entrega cada mensaje del mercado
  def self.market_routing_key(message)
    message['type'] == 'market-closed' ? 'market.closed' : "market.offer.#{message['cityId']}"
  end

  def self.without(field, message)
    message.reject { |key, _| key == field }
  end
end
