require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "logs a NACK with the payload idpk and original payload" do
    payload = { "idpk" => "message-1", "type" => "transfer" }

    audit_log = AuditLog.log_nack(payload, "MALFORMED MESSAGE")

    assert_equal "message-1", audit_log.idpk
    assert_equal "NACK", audit_log.event_type
    assert_equal "MALFORMED MESSAGE", audit_log.reason
    assert_equal payload, audit_log.raw_payload
  end

  test "logs a NACK even when the payload has no idpk" do
    audit_log = AuditLog.log_nack({ "type" => "transfer" }, "IDENTITY MISMATCH")

    assert_nil audit_log.idpk
    assert_equal "NACK", audit_log.event_type
  end

  test "logs a discarded raw string without an idpk" do
    raw_string = "{invalid json"

    audit_log = AuditLog.log_discard(raw_string, "UNPARSEABLE MESSAGE")

    assert_nil audit_log.idpk
    assert_equal "DISCARDED", audit_log.event_type
    assert_equal "UNPARSEABLE MESSAGE", audit_log.reason
    assert_equal({ "raw_string" => raw_string }, audit_log.raw_payload)
  end

  test "logs replies from the central with their own event type" do
    { "ack" => "CENTRAL_ACK", "nack" => "CENTRAL_NACK", "error" => "CENTRAL_ERROR" }.each do |type, event_type|
      audit_log = AuditLog.log_central({ "idpk" => "idpk-#{type}", "type" => type }, "falta el campo timestamp")

      assert_equal event_type, audit_log.event_type
      assert_equal "idpk-#{type}", audit_log.idpk
    end
  end

  test "logs a central reply without idpk" do
    audit_log = AuditLog.log_central({ "type" => "ack" }, "falta el campo idpk")

    assert_nil audit_log.idpk
    assert_equal "CENTRAL_ACK", audit_log.event_type
  end

  test "returns nil when NACK audit persistence fails" do
    assert_nil AuditLog.log_nack(nil, "MALFORMED MESSAGE")
  end

  test "returns nil when discarded audit persistence fails" do
    assert_nil AuditLog.log_discard("raw", nil)
  end
end