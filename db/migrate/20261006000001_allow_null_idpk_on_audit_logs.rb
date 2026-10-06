class AllowNullIdpkOnAuditLogs < ActiveRecord::Migration[8.0]
  def change
    change_column_null :audit_logs, :idpk, true
  end
end