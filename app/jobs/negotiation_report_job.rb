class NegotiationReportJob < ApplicationJob
  queue_as :default

  def perform(cycle_id)
    # Consultar balances desde el Ledger (Falta hacer Ledger)
    # Se obtienen las métricas acumuladas reales del ciclo
    
    energy_balance = Transaction.sum(:energy_change)
    budget_balance = Transaction.sum(:budget_change)

    report_payload = CycleService.build_negotiation_report(
      cycle_id: cycle_id,
      budget_balance: budget_balance,
      energy_balance: energy_balance
    )

    Rails.logger.info "[NegotiationReportJob] Enviando negotiation-report para el ciclo #{cycle_id}"
    RabbitMQPublisher.publish(report_payload) if defined?(RabbitMQPublisher)
  end
end