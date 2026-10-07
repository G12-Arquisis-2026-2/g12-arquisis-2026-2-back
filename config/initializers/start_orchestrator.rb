Rails.application.config.after_initialize do
  # Solo el servidor web arranca la cadena del orquestador. Rails::Server existe únicamente con
  # `rails server`; db:prepare, db:migrate, assets:precompile, cualquier tarea rake, la consola,
  # runner, bin/jobs y los tests cargan la app sin él.
  CycleOrchestratorJob.start_chain if defined?(Rails::Server)
end
