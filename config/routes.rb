Rails.application.routes.draw do
  root to: 'history#index'
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"

  # Healthcheck para RNF7
  get '/healthz', to: proc { [200, {}, ['ok']] }

  # Recepción desde el connector
  post '/events', to: 'events#create'
  post '/events/rejected', to: 'events#rejected'

  # Endpoints requeridos (RF1, RF2, RF3, RF4)
  get '/history', to: 'history#index'
  get '/history/:id', to: 'history#show'


  # --- ENDPOINTS E1 PARA EL FRONTEND ---

  # RF01: Historial de ciclos
  get '/cycles',     to: 'cycles#index'
  get '/cycles/:id', to: 'cycles#show'

  # RF02: Tabla de conectividad vigente
  get '/connectivity', to: 'connectivity#index'

  # RF04: Negociaciones voluntarias (listar y proponer)
  get  '/proposals', to: 'proposals#index'
  post '/proposals', to: 'proposals#create'

  # RF05: Auditoría de anomalías (duplicados, descartes y NACKs)
  get '/audit-logs', to: 'audit_logs#index'

  namespace :api do
    namespace :v1 do
      get "ledger/:cycle_id", to: "ledger#show", as: :ledger
      get "distances", to: "distances#index", as: :distances
      get "audit-logs", to: "audit_logs#index", as: :audit_logs
    end
  end
end
