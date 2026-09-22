require 'bunny'
require 'net/http'
require 'json'
require 'uri'

rabbitmq_url = ENV.fetch('RABBITMQ_URL', 'amqps://observer.22:0sxW2ynRgBZ5A6k7x5ezNAnp@broker.iic2173.org:5671/energy')
observer_id  = ENV.fetch('OBSERVER_ID', '22')
queue_name   = "observer.#{observer_id}.q"
rails_api    = URI(ENV.fetch('MASTER_URL', 'http://master1:3000/events'))

loop do
  begin
    puts "[Connector] Conectando a #{rabbitmq_url}..."
    # tls: true y verify_peer: false para evitar el warning de certificado cliente
    conn = Bunny.new(rabbitmq_url, tls: true, tls_silence_warnings: true, verify_peer: false, automatically_recover: true)
    conn.start

    ch = conn.create_channel
    # passive: true evita el error de permisos (ACCESS_REFUSED)
    queue = ch.queue(queue_name, passive: true)

    puts "[Connector] Escuchando en '#{queue_name}'..."

    queue.subscribe(manual_ack: true, block: true) do |delivery_info, _properties, body|
      parsed = JSON.parse(body)

      req = Net::HTTP::Post.new(rails_api, 'Content-Type' => 'application/json')
      req.body = parsed.to_json
      res = Net::HTTP.start(rails_api.hostname, rails_api.port) { |http| http.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        ch.ack(delivery_info.delivery_tag)
        puts "[Connector] Evento #{parsed['idpk']} procesado."
      else
        ch.nack(delivery_info.delivery_tag, false, true)
      end
    end
  rescue StandardError => e
    puts "[Connector Error] #{e.message}. Reintentando en 5s..."
    sleep 5
  end
end
