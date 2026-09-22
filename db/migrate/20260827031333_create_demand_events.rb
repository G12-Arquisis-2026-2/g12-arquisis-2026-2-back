class CreateDemandEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :demand_events do |t|
      t.string :idpk, null: false, index: { unique: true }
      t.string :event_type, null: false
      t.jsonb :package_body, null: false, default: {}
      t.datetime :received_at, null: false

      t.timestamps
    end
    add_index :demand_events, :received_at
  end
end
