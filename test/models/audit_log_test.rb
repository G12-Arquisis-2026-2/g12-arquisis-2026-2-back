require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
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
    assert_equal raw_string, audit_log.raw_payload
  end

  test "silently returns nil when audit persistence fails" do
    AuditLog.stub(:create!, ->(**_attributes) { raise "database unavailable" }) do
      assert_nil AuditLog.log_discard("raw", "UNPARSEABLE MESSAGE")
    end
  end
end