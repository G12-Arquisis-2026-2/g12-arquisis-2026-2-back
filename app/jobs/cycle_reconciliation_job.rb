class CycleReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    wallet_balance = WalletClient.new.get_balance
    return unless wallet_balance.is_a?(Hash)

    settled = SwapIntention.settled
    expected = {
      "CR" => settled.sum(:take_amount).to_d - settled.sum(:give_amount).to_d,
      "KWH" => settled.sum(:give_amount).to_d - settled.sum(:take_amount).to_d
    }

    balances = wallet_balance["balances"] || wallet_balance
    actual = {
      "CR" => decimal_value(balances["CR"] || balances["cr"]),
      "KWH" => decimal_value(balances["KWH"] || balances["kwh"])
    }

    %w[CR KWH].each do |currency|
      next if expected[currency] == actual[currency]

      Rails.logger.warn(
        "[CycleReconciliationJob] Delta de balance #{currency}: " \
        "esperado=#{expected[currency]}, real=#{actual[currency]}"
      )
    end
  end

  private

  def decimal_value(value)
    return 0.to_d if value.nil?

    value.respond_to?(:to_d) ? value.to_d : BigDecimal(value.to_s)
  end
end
