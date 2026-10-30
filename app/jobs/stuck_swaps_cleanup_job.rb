require "securerandom"

class StuckSwapsCleanupJob < ApplicationJob
  queue_as :default

  def perform
    SwapIntention.pending.where("expires_at < ?", Time.current).find_each do |intention|
      next if intention.swap_id.blank?

      result = WalletClient.new.cancel_swap(
        swap_id: intention.swap_id,
        idempotency_key: SecureRandom.uuid
      )

      intention.cancelled! if result&.success?
    end
  end
end
