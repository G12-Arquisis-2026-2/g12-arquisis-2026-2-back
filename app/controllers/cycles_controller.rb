class CyclesController < ApplicationController

    def index
        # Mock data que simula el historial de ciclos
        render json: {
          cycles: [
            {
              cycleId: "cycle-9431",
              statusStatement: {
                energy: {
                  generationCapacity: 1234512,
                  consumption: 1444121,
                  generationCost: 210
                },
                validUntil: "2026-09-01T14:20:00Z"
              },
              fundsReceived: 508145,
              demandStatements: [
                {
                  quantity: 1500,
                  valuePerKwh: 215,
                  appliedAt: "2026-09-01T14:05:00Z"
                }
              ],
              voluntaryNegotiations: [
                {
                  proposalId: "prop-001",
                  direction: "take",
                  quantity: 2024,
                  pricePerEnergy: 210,
                  status: "paid"
                }
              ],
              negotiationReport: {
                budgetBalance: 131212,
                energyBalance: 1232,
                sentAt: "2026-09-01T14:15:00Z"
              },
              finalBalances: {
                budget: 131212,
                energy: 1232
              },
              lastOperation: "negotiation-report"
            }
          ]
        }, status: :ok
    end
    
    def show
      # Detalle de un ciclo específico
      render json: {
          cycleId: params[:id],
          statusStatement: {
            energy: { generationCapacity: 1234512, consumption: 1444121, generationCost: 210 },
            validUntil: "2026-09-01T14:20:00Z"
          },
          fundsReceived: 508145,
          demandStatements: [],
          voluntaryNegotiations: [],
          negotiationReport: { budgetBalance: 131212, energyBalance: 1232 },
          finalBalances: { budget: 131212, energy: 1232 },
          lastOperation: "status-statement"
        }, status: :ok
    end
end