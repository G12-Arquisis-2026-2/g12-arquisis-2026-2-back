# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_06_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "audit_logs", force: :cascade do |t|
    t.string "idpk"
    t.string "event_type", null: false
    t.string "reason", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
  end

  create_table "cycles", force: :cascade do |t|
    t.string "cycle_id", null: false
    t.decimal "generation_capacity"
    t.decimal "consumption"
    t.decimal "generation_cost"
    t.decimal "reported_budget"
    t.decimal "reported_energy"
    t.boolean "report_sent", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_until"
    t.string "report_idpk"
    t.string "report_msg_id"
    t.datetime "report_not_before"
    t.datetime "report_missed_at"
    t.bigint "market_strategy_id"
    t.integer "sellable"
    t.decimal "buyback_price", precision: 15, scale: 2
    t.decimal "imbalance_price", precision: 15, scale: 2
    t.integer "min_bid"
    t.datetime "market_opens_at"
    t.datetime "last_offer_at"
    t.datetime "last_bid_at"
    t.datetime "closes_at"
    t.datetime "report_opens_at"
    t.datetime "market_closed_at"
    t.decimal "cr_delta", precision: 20, scale: 2
    t.decimal "kwh_delta", precision: 20, scale: 2
    t.datetime "reconciliation_scheduled_at"
    t.datetime "reconciled_at"
    t.index ["cycle_id"], name: "index_cycles_on_cycle_id", unique: true
    t.index ["market_strategy_id"], name: "index_cycles_on_market_strategy_id"
    t.index ["report_msg_id"], name: "index_cycles_on_report_msg_id"
  end

  create_table "demand_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "idpk", null: false
    t.jsonb "package_body", default: {}, null: false
    t.datetime "received_at", null: false
    t.datetime "updated_at", null: false
    t.index ["idpk"], name: "index_demand_events_on_idpk", unique: true
    t.index ["received_at"], name: "index_demand_events_on_received_at"
  end

  create_table "distance_tables", force: :cascade do |t|
    t.string "destination_code", null: false
    t.integer "distance", null: false
    t.decimal "transport_cost", null: false
    t.boolean "enabled", null: false
    t.decimal "disabled_route_transport_cost", precision: 15, scale: 6
    t.index ["destination_code"], name: "index_distance_tables_on_destination_code", unique: true
  end

  create_table "market_bids", force: :cascade do |t|
    t.string "cycle_id", null: false
    t.string "offer_id", null: false
    t.string "bid_idpk", null: false
    t.string "bid_msg_id", null: false
    t.string "side", null: false
    t.string "buyer_city", null: false
    t.string "seller_city", null: false
    t.integer "quantity", null: false
    t.decimal "price_per_energy", precision: 15, scale: 2
    t.decimal "amount", precision: 15, scale: 2
    t.string "status", default: "pending", null: false
    t.string "proposal_idpk"
    t.string "accept_idpk"
    t.string "swap_id"
    t.datetime "expires_at"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accept_idpk"], name: "index_market_bids_on_accept_idpk", unique: true
    t.index ["bid_idpk"], name: "index_market_bids_on_bid_idpk", unique: true
    t.index ["bid_msg_id"], name: "index_market_bids_on_bid_msg_id", unique: true
    t.index ["cycle_id", "side", "status"], name: "index_market_bids_on_cycle_id_and_side_and_status"
    t.index ["proposal_idpk"], name: "index_market_bids_on_proposal_idpk", unique: true
    t.index ["swap_id"], name: "index_market_bids_on_swap_id"
  end

  create_table "market_offers", force: :cascade do |t|
    t.string "cycle_id", null: false
    t.string "offer_id", null: false
    t.string "city_id", null: false
    t.integer "quantity", null: false
    t.integer "remaining", null: false
    t.integer "reserved_quantity", default: 0, null: false
    t.decimal "price_per_energy", precision: 15, scale: 2, null: false
    t.boolean "active", default: true, null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cycle_id", "active", "remaining"], name: "index_market_offers_on_cycle_id_and_active_and_remaining"
    t.index ["cycle_id", "city_id", "offer_id"], name: "index_market_offers_on_cycle_id_and_city_id_and_offer_id", unique: true
  end

  create_table "market_strategies", force: :cascade do |t|
    t.decimal "sell_price_multiplier", precision: 8, scale: 4, default: "1.1", null: false
    t.decimal "max_buy_effective_price_ratio", precision: 8, scale: 4, default: "1.0", null: false
    t.integer "span_seconds", default: 60, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_market_strategies_on_active", unique: true, where: "active"
  end

  create_table "outbox_messages", force: :cascade do |t|
    t.string "msg_id", null: false
    t.string "idpk", null: false
    t.string "message_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.string "error"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "exchange"
    t.string "routing_key"
    t.string "reply_to_idpk"
    t.index ["msg_id"], name: "index_outbox_messages_on_msg_id", unique: true
    t.index ["reply_to_idpk"], name: "index_outbox_messages_on_reply_to_idpk"
    t.index ["status"], name: "index_outbox_messages_on_status"
  end

  create_table "processed_messages", force: :cascade do |t|
    t.string "idpk", null: false
    t.string "message_type", null: false
    t.datetime "created_at", null: false
    t.index ["idpk"], name: "index_processed_messages_on_idpk", unique: true
  end

  create_table "proposals", force: :cascade do |t|
    t.string "idpk", null: false
    t.string "cycle_id", null: false
    t.string "direction", null: false
    t.decimal "quantity", precision: 15, scale: 2, null: false
    t.decimal "price_per_energy", precision: 15, scale: 2
    t.decimal "generation_cost", precision: 15, scale: 2, null: false
    t.string "status", default: "PENDING", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status_reason"
    t.datetime "confirmed_at"
    t.integer "transfer_retries", default: 0, null: false
    t.datetime "last_transfer_retry_at"
    t.index ["cycle_id"], name: "index_proposals_on_cycle_id"
    t.index ["idpk"], name: "index_proposals_on_idpk", unique: true
  end

  create_table "swap_intentions", force: :cascade do |t|
    t.string "idpk", null: false
    t.string "swap_id"
    t.integer "status", default: 0, null: false
    t.decimal "give_amount"
    t.decimal "take_amount"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "cycle_id"
    t.string "cancel_idempotency_key"
    t.index ["cancel_idempotency_key"], name: "index_swap_intentions_on_cancel_idempotency_key", unique: true
    t.index ["cycle_id"], name: "index_swap_intentions_on_cycle_id"
    t.index ["idpk"], name: "index_swap_intentions_on_idpk", unique: true
  end

  create_table "transactions", force: :cascade do |t|
    t.string "idpk", null: false
    t.string "cycle_id", null: false
    t.string "operation_type", null: false
    t.decimal "energy_change", null: false
    t.decimal "budget_change", null: false
    t.jsonb "raw_data", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["cycle_id"], name: "index_transactions_on_cycle_id"
    t.index ["idpk"], name: "index_transactions_on_idpk", unique: true
  end

  add_foreign_key "cycles", "market_strategies"
end
