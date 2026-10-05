Rails.application.config.after_initialize do
  # Filtro para evitar que el Job se encole al ejecutar migraciones, consola o tareas rake
  is_console = defined?(Rails::Console)
  is_rake    = File.basename($PROGRAM_NAME) == 'rake' || $PROGRAM_NAME.include?('rails') && ARGV.include?('db:migrate')

  unless is_console || is_rake
    Rails.logger.info "[Boot] Contenedor iniciado. Encolando el primer CycleOrchestratorJob..."
    
    # Encola el Job inmediatamente al arrancar
    CycleOrchestratorJob.perform_later
  end
end