class CyclesController < ApplicationController
  # GET /cycles (Historial de todos los ciclos)
  def index
    cycles = Cycle.where.not(valid_until: nil).order(valid_until: :desc)
    formatted_cycles = cycles.map { |cycle| CyclePresenter.format(cycle) }

    render json: { cycles: formatted_cycles }, status: :ok
  end

  # GET /cycles/current (Obtiene el ciclo activo actual)
  def current
    cycle = Cycle.where.not(valid_until: nil).order(valid_until: :desc).first

    if cycle
      render json: { cycle: CyclePresenter.format(cycle) }, status: :ok
    else
      render json: { error: "NO_ACTIVE_CYCLE", detail: "No hay un ciclo registrado aún" }, status: :not_found
    end
  end

  # GET /cycles/:id (Detalle de un ciclo específico por cycle_id)
  def show
    cycle = Cycle.find_by(cycle_id: params[:id])

    if cycle
      render json: { cycle: CyclePresenter.format(cycle) }, status: :ok
    else
      render json: { error: "NOT_FOUND", detail: "Ciclo #{params[:id]} no encontrado" }, status: :not_found
    end
  end
end