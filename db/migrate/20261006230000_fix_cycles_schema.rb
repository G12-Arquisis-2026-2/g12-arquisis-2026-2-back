class FixCyclesSchema < ActiveRecord::Migration[8.1]
  def change
    change_column_null :cycles, :cycle_id, false
    change_column_default :cycles, :report_sent, from: nil, to: false
  end
end