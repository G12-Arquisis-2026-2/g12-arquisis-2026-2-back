class WalletRetryJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 12

  def perform(operation:, path:, payload:, idempotency_key:)
    raise ArgumentError, "Unsupported Wallet operation #{operation.inspect}" unless operation == "wallet_http"

    Rails.logger.info(
      "[WalletRetryJob] Reintentando #{path} con idempotency_key=#{idempotency_key}"
    )

    client = WalletClient.new
    result = client.send(:post, path, payload, idempotency_key, enqueue_retry: false)
    raise WalletClient::RetryableFailure, "Wallet respondió #{result.status}" unless result.success?
  end
end
