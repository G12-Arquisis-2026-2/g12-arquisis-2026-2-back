class PreserveDisabledRouteTransportPrecision < ActiveRecord::Migration[8.1]
  def change
    change_column :distance_tables, :disabled_route_transport_cost, :decimal, precision: 15, scale: 6
  end
end
