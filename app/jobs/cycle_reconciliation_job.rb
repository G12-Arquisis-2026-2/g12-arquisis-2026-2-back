class CycleReconciliationJob < ApplicationJob
  queue_as :default

  def perform(cycle_id)
    cycle = Cycle.find_by(cycle_id: cycle_id)
    return unless cycle

    wallet_balance = WalletClient.new.get_balance
    return unless wallet_balance.is_a?(Hash)

    balances = wallet_balance["balances"] || wallet_balance
    actual_cr = decimal_value(balances["CR"] || balances["cr"])
    actual_kwh = decimal_value(balances["KWH"] || balances["kwh"])

    settled = SwapIntention.settled.where(cycle_id: cycle_id)
    expected_cr = settled.sum(:take_amount).to_d - settled.sum(:give_amount).to_d
    expected_kwh = settled.sum(:give_amount).to_d - settled.sum(:take_amount).to_d

    cycle.update!(
      cr_delta: actual_cr - expected_cr,
      kwh_delta: actual_kwh - expected_kwh,
      reconciled_at: Time.current
    )
  end

  private

  def decimal_value(value)
    return 0.to_d if value.nil?

    value.respond_to?(:to_d) ? value.to_d : BigDecimal(value.to_s)
  end
end
