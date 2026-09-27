class AuditLogsController < ApplicationController
    def index
      render json: {
        duplicates: [
          {
            idpk: "a81c12e2-9b21-4f11-b0d3-1a2f4c5e6d78",
            originalMsgId: "msg-001",
            duplicateMsgId: "msg-002",
            type: "demand-statement",
            detectedAt: (Time.current - 5.minutes).iso8601,
            action: "ignored_ledger_unchanged"
          }
        ],
        rejectedMessages: [
          {
            msgId: "msg-999",
            reason: "MALFORMED_MESSAGE",
            code: 422,
            message: "quantity must be a positive number",
            timestamp: (Time.current - 12.minutes).iso8601,
            type: "nack"
          },
          {
            msgId: "msg-888",
            reason: "IDPK_EQUALS_MSGID",
            code: 422,
            message: "idpk and msgId must differ",
            timestamp: (Time.current - 30.minutes).iso8601,
            type: "nack"
          },
          {
            msgId: nil,
            reason: "UNPARSEABLE_OR_MISSING_MSGID",
            code: nil,
            message: "Dropped silently to logs",
            timestamp: (Time.current - 45.minutes).iso8601,
            type: "discarded"
          }
        ]
      }, status: :ok
    end
end