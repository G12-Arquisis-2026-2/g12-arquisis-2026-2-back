require "test_helper"

class ProposalsControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "does not route legacy proposal creation" do
    post "/proposals", params: { cycleId: "cycle-1", direction: "take", energy: 10 }.to_json,
                       headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :not_found
    assert_equal 0, Proposal.count
    assert_equal 0, OutboxMessage.count
  end
end
