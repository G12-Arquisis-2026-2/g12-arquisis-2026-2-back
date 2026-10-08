module Api
  module V1
    class LedgerController < ApplicationController
      def show
        cycle_id = params[:cycle_id]
        transactions = Transaction.where(cycle_id: cycle_id).order(created_at: :desc)

        render json: {
          current_balance: Transaction.current_balance_for(cycle_id),
          history: transactions
        }, status: :ok
      end
    end
  end
end