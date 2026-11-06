# idpk del bid al que responde un bid-accepted o bid-rejected.
# Sirve para volver a enviar la misma respuesta si el bid llega repetido (anomalía 1).
class AddReplyToIdpkToOutboxMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :outbox_messages, :reply_to_idpk, :string
    add_index :outbox_messages, :reply_to_idpk
  end
end
