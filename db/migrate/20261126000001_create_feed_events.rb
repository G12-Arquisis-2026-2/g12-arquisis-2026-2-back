class CreateFeedEvents < ActiveRecord::Migration[8.0]
    def change
      create_table :feed_events do |t|
        t.string :event_type, null: false
        t.string :cycle_id
        t.string :swap_id
        t.string :idpk
        t.jsonb  :payload, null: false, default: {}
  
        t.timestamps
      end
  
      add_index :feed_events, :created_at
      add_index :feed_events, :cycle_id
      add_index :feed_events, :swap_id
    end
  end