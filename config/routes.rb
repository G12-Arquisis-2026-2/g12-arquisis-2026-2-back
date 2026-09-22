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

  # Endpoints requeridos (RF1, RF2, RF3, RF4)
  get '/history', to: 'history#index'
  get '/history/:id', to: 'history#show'
end
