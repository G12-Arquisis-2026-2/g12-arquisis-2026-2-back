Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Lista de orígenes permitidos
    origins [
      # Desarrollo local (Vite/React suele correr en 5173, Next/CRA en 3000)
      'http://localhost:5173',
      'http://127.0.0.1:5173',
      'http://localhost:3000',
      'http://127.0.0.1:3000',

      # Producción: Dominio o distribución de CloudFront del frontend
      # Reemplaza con el dominio real cuando el Integrante 5 lo despliegue
      %r{\Ahttps://.*\.cloudfront\.net\z},
      %r{\Ahttps://(www\.)?cmlagb\.me\z}
    ]

    resource '*',
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      credentials: false # Déjalo en false si usarás Bearer tokens estándar con Auth0/Cognito
  end
end
