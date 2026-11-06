require "test_helper"

class WalletClientTest < ActiveSupport::TestCase
  class CapturingHttpClient
    attr_reader :captured_request

    def request(request)
      @captured_request = request
      SuccessfulResponse.new
    end
  end

  class SuccessfulResponse < Net::HTTPSuccess
    def initialize
      super("1.1", "201", "Created")
    end

    def body
      "{}"
    end
  end

  test "serializes BigDecimal amounts nested in swap payloads as JSON numbers" do
    http = CapturingHttpClient.new
    client = WalletClient.new(base_url: "https://wallet.example", api_key: "test")
    client.define_singleton_method(:http_client) { |_uri| http }

    client.propose_swap(
      give: { asset: "KWH", amount: 10 },
      take: { asset: "CR", amount: BigDecimal("12.50") },
      memo: "offer-1",
      expires_at: 1.minute.from_now.iso8601,
      idempotency_key: "proposal-1"
    )

    amount = JSON.parse(http.captured_request.body).dig("take", "amount")
    assert_equal 12.5, amount
    assert_kind_of Numeric, amount
  end
end
