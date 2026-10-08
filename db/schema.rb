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

ActiveRecord::Schema[8.1].define(version: 2026_10_08_200000) do
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
    t.index ["cycle_id"], name: "index_cycles_on_cycle_id", unique: true
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
    t.index ["destination_code"], name: "index_distance_tables_on_destination_code", unique: true
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
    t.index ["msg_id"], name: "index_outbox_messages_on_msg_id", unique: true
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
end
