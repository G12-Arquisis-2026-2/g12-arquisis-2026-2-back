# Destino de cada mensaje del outbox. Vacíos = a la central, como en la E1.
# exchange "market" + routing_key "market.offer.TK3": nuestra oferta.
# exchange vacío + routing_key "city.HGW": a otra ciudad por el exchange de siempre.
class AddDestinationToOutboxMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :outbox_messages, :exchange, :string
    add_column :outbox_messages, :routing_key, :string
  end
end
