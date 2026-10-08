class AddReportTrackingToCycles < ActiveRecord::Migration[8.1]
  def change
    # idpk y msgId del último negotiation-report encolado: un reintento reusa el idpk,
    # y el msgId sirve para reconocer el error REPORT_TOO_EARLY (data.target)
    add_column :cycles, :report_idpk, :string
    add_column :cycles, :report_msg_id, :string
    # la central dijo REPORT_TOO_EARLY: reenviar desde data.opensAt
    add_column :cycles, :report_not_before, :datetime
    # la ventana cerró sin reporte entregado (queda también en audit_logs)
    add_column :cycles, :report_missed_at, :datetime

    add_index :cycles, :report_msg_id
  end
end
