module Api
  module V1
    class AuditLogsController < ApplicationController
      def index
        audit_logs = AuditLog.order(created_at: :desc)
        render json: audit_logs, status: :ok
      end
    end
  end
end