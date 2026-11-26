ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # RabbitMQPublisher exige la transacción del cambio de estado (ADR8). La de los fixtures no cuenta
    # (no es joinable), así que los tests que lo usan para preparar datos la abren con estos helpers.
    def publish_outbox(*args, **kwargs)
      ApplicationRecord.transaction { RabbitMQPublisher.publish(*args, **kwargs) }
    end

    def resend_bid_reply_outbox(bid)
      ApplicationRecord.transaction { RabbitMQPublisher.resend_bid_reply(bid) }
    end
  end
end
