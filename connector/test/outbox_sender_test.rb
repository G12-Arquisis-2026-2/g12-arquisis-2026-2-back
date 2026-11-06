require 'minitest/autorun'
require_relative '../lib/master_client'
require_relative '../lib/offer_memory'
require_relative '../lib/outbox_sender'

# correr desde /connector: ruby test/outbox_sender_test.rb
class OutboxSenderTest < Minitest::Test
  class FakeMaster
    attr_reader :marks

    def initialize(pending, mark_status: 200)
      @pending = pending
      @mark_status = mark_status
      @marks = []
    end

    # como la API: lo que ya se marco (enviado o fallido) deja de estar pendiente
    def pending_outbox
      marked = @marks.map(&:first)
      @pending.reject { |item| marked.include?(item['id']) }
    end

    def mark_outbox(id, status, reason = nil)
      @marks << [id, status, reason]
      MasterClient::Result.new(@mark_status, '{}')
    end
  end

  class FakePublisher
    attr_reader :published, :reopened
    attr_accessor :closed_reason, :open

    # close_on: msgId que hace que el broker cierre el canal (como una publicacion sin permiso)
    def initialize(confirm: true, error: nil, close_on: nil)
      @confirm = confirm
      @error = error
      @close_on = close_on
      @published = []
      @reopened = 0
      @open = true
    end

    attr_reader :destinations

    # como bunny: el broker cierra el canal y wait_for_confirms termina por timeout
    def publish_confirmed(message, exchange: nil, routing_key: nil)
      raise @error if @error
      raise Timeout::Error if refuse?(message)

      @published << message
      (@destinations ||= []) << [exchange, routing_key]
      @confirm
    end

    def channel_open?
      @open && @closed_reason.nil?
    end

    def closed_by_broker
      @closed_reason
    end

    def reopen_channel
      @reopened += 1
      @closed_reason = nil
    end

    private

    def refuse?(message)
      return false unless message['msgId'] == @close_on

      @closed_reason = "ACCESS_REFUSED - access to exchange 'market' refused for user 'city.12'"
    end
  end

  def outgoing(changes = {})
    {
      'msgId' => '11111111-1111-4111-8111-111111111111',
      'idpk' => '22222222-2222-4222-8222-222222222222',
      'type' => 'negotiation-report',
      'timestamp' => '2026-10-07T14:00:00Z',
      'cityId' => '12',
      'cycleId' => 'cycle-7',
      'data' => { 'budgetBalance' => 10, 'energyBalance' => -3 }
    }.merge(changes)
  end

  # cada payload puede ir solo (a la central) o como [payload, exchange, routing_key]
  def build_sender(payloads, publisher: FakePublisher.new, mark_status: 200, enabled: true, limiter: nil, offers: nil)
    pending = payloads.each_with_index.map do |item, index|
      payload, exchange, routing_key = item.is_a?(Array) ? item : [item]
      { 'id' => index + 1, 'payload' => payload, 'exchange' => exchange, 'routing_key' => routing_key }
    end
    @master = FakeMaster.new(pending, mark_status: mark_status)
    @publisher = publisher
    @logs = []
    options = { master: @master, publisher: publisher, city_id: '12', log: ->(text) { @logs << text },
                enabled: enabled, offers: offers }
    options[:limiter] = limiter if limiter
    OutboxSender.new(**options)
  end

  def run_sender(payloads, **options)
    build_sender(payloads, **options).run_once
  end

  def test_disabled_does_not_publish_nor_mark_and_logs_what_it_would_send
    second = outgoing('msgId' => '33333333-3333-4333-8333-333333333333')
    run_sender([outgoing, second], enabled: false)

    assert_empty @publisher.published
    assert_empty @master.marks
    assert_equal 2, @logs.size
    assert_includes @logs.first, 'ENABLE_PUBLISHER apagado'
    %w[negotiation-report 11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 cityId=12].each do |part|
      assert_includes @logs.first, part
    end
    refute_includes @logs.first, 'budgetBalance'
  end

  def test_disabled_logs_each_pending_only_once_across_rounds
    sender = build_sender([outgoing], enabled: false)
    3.times { sender.run_once }

    assert_empty @publisher.published
    assert_empty @master.marks
    assert_equal 1, @logs.size
  end

  def test_disabled_still_marks_invalid_messages_as_failed
    run_sender([outgoing('cityId' => '99')], enabled: false)

    assert_empty @publisher.published
    assert_equal [1, 'failed'], @master.marks.first.first(2)
  end

  def test_publishes_the_message_as_is_and_marks_it_sent
    run_sender([outgoing])

    assert_equal [outgoing], @publisher.published
    assert_equal [[1, 'sent', nil]], @master.marks
  end

  def test_publishes_in_order
    second = outgoing('msgId' => '33333333-3333-4333-8333-333333333333')
    run_sender([outgoing, second])

    assert_equal [outgoing, second], @publisher.published
    assert_equal [1, 2], @master.marks.map(&:first)
  end

  def test_foreign_city_id_is_not_published_and_is_marked_failed
    run_sender([outgoing('cityId' => '99')])

    assert_empty @publisher.published
    assert_equal [1, 'failed'], @master.marks.first.first(2)
    assert_includes @master.marks.first.last, 'cityId'
  end

  def test_missing_fields_and_equal_ids_are_marked_failed
    same = outgoing('idpk' => outgoing['msgId'])
    bad = %w[msgId idpk type timestamp].map { |field| outgoing.reject { |key, _| key == field } } + [same, 'texto']
    run_sender(bad)

    assert_empty @publisher.published
    assert_equal ['failed'] * 6, @master.marks.map { |mark| mark[1] }
  end

  def test_a_bad_message_does_not_block_the_next_one
    run_sender([outgoing('cityId' => '99'), outgoing])

    assert_equal [outgoing], @publisher.published
    assert_equal %w[failed sent], @master.marks.map { |mark| mark[1] }
  end

  def test_publish_error_leaves_it_pending_and_stops_the_round
    run_sender([outgoing, outgoing], publisher: FakePublisher.new(error: RuntimeError.new('sin conexion')))

    assert_empty @master.marks
    assert_equal 1, @logs.count { |line| line.include?('queda pendiente') }
  end

  def test_unconfirmed_publish_leaves_it_pending
    run_sender([outgoing], publisher: FakePublisher.new(confirm: false))

    assert_empty @master.marks
  end

  def test_failed_mark_is_logged_and_does_not_crash
    run_sender([outgoing], mark_status: nil)

    assert_equal [outgoing], @publisher.published
    assert(@logs.any? { |line| line.include?('se va a reenviar') })
  end

  def test_nothing_pending_does_nothing
    run_sender([])

    assert_empty @publisher.published
    assert_empty @master.marks
  end

  # --- protocolo v3: envio con destino ---

  def to_city(code = 'HGW', changes = {})
    [outgoing({ 'type' => 'bid' }.merge(changes)), nil, "city.#{code}"]
  end

  def to_market(routing_key = 'market.offer.12', changes = {})
    [outgoing({ 'type' => 'offer' }.merge(changes)), 'market', routing_key]
  end

  def test_without_destination_goes_to_the_central_as_before
    run_sender([outgoing])

    assert_equal [[nil, nil]], @publisher.destinations
  end

  def test_message_to_another_city_uses_its_routing_key
    run_sender([to_city])

    assert_equal [[nil, 'city.HGW']], @publisher.destinations
    assert_equal [[1, 'sent', nil]], @master.marks
    assert(@logs.any? { |line| line.include?('hacia city.HGW') })
  end

  def test_offer_to_the_market_uses_our_routing_key
    run_sender([to_market])

    assert_equal [['market', 'market.offer.12']], @publisher.destinations
  end

  def test_market_publication_with_another_routing_key_is_marked_failed
    ['market.offer.HGW', 'market.offer.#', 'market.bid.12', ''].each do |routing_key|
      run_sender([to_market(routing_key)])

      assert_empty @publisher.published, routing_key
      assert_equal 'failed', @master.marks.first[1]
      assert_includes @master.marks.first[2], 'market.offer.12'
    end
  end

  def test_unknown_exchange_or_bad_city_routing_key_is_marked_failed
    [[outgoing, 'amq.topic', 'city.HGW'], [outgoing, nil, 'central.x'], [outgoing, nil, 'city.'],
     [outgoing, nil, 'city.#']].each do |item|
      run_sender([item])

      assert_empty @publisher.published, item.inspect
      assert_equal 'failed', @master.marks.first[1]
    end
  end

  class FakeClock
    attr_accessor :now

    def initialize
      @now = 0.0
    end

    def call
      @now
    end
  end

  def limited_sender(payloads)
    @clock = FakeClock.new
    limiter = RateLimiter.new(limit: OutboxSender::MARKET_LIMIT_PER_MINUTE, window: 60, clock: @clock)
    build_sender(payloads, limiter: limiter)
  end

  def bids(count, start = 0)
    (start...(start + count)).map do |index|
      to_city('HGW', 'msgId' => format('aaaaaaaa-0000-4000-8000-%012d', index))
    end
  end

  def test_no_more_than_50_market_or_city_messages_per_minute
    sender = limited_sender(bids(55) + [to_market])
    sender.run_once

    assert_equal 50, @publisher.published.size
    assert_equal (1..50).to_a, @master.marks.map(&:first)
    assert(@logs.any? { |line| line.include?('6 pendientes esperan') })
  end

  def test_the_rest_go_out_when_the_window_slides
    sender = limited_sender(bids(55))
    sender.run_once

    @clock.now = 59.9
    sender.run_once
    assert_equal 50, @publisher.published.size

    @clock.now = 60.0
    sender.run_once
    assert_equal 55, @publisher.published.size
  end

  def test_central_messages_are_not_limited_nor_blocked_by_the_limit
    report = outgoing('type' => 'negotiation-report', 'msgId' => '99999999-9999-4999-8999-999999999999')
    run = bids(51) + [report]
    sender = limited_sender(run)
    sender.run_once

    assert_equal 51, @publisher.published.size
    assert_equal report, @publisher.published.last
  end

  def test_disabled_does_not_use_the_quota
    limiter = RateLimiter.new(limit: 1, window: 60, clock: FakeClock.new)
    build_sender(bids(3), enabled: false, limiter: limiter).run_once

    assert limiter.take
  end

  # --- canal del outbox cerrado por el broker ---

  def test_channel_closed_by_the_broker_marks_the_message_failed_reopens_and_goes_on
    refused = to_market('market.offer.12', 'msgId' => '33333333-3333-4333-8333-333333333333')
    publisher = FakePublisher.new(close_on: refused.first['msgId'])
    run_sender([refused, outgoing], publisher: publisher)

    assert_equal 'failed', @master.marks.first[1]
    assert_includes @master.marks.first[2], 'ACCESS_REFUSED'
    assert_equal 1, publisher.reopened
    assert_equal [outgoing], publisher.published
    assert_equal [2, 'sent', nil], @master.marks.last
    assert(@logs.any? { |line| line.include?('el broker cerró el canal del outbox') })
  end

  def test_channel_closed_by_the_broker_between_rounds_is_reopened_before_publishing
    publisher = FakePublisher.new
    publisher.closed_reason = 'NOT_FOUND - no exchange'
    run_sender([outgoing], publisher: publisher)

    assert_equal 1, publisher.reopened
    assert_equal [outgoing], publisher.published
  end

  # cerrado por un corte de red: lo recupera bunny, no se marca nada ni se abre otro canal
  def test_channel_closed_by_a_network_failure_waits_for_bunny
    publisher = FakePublisher.new
    publisher.open = false
    run_sender([outgoing], publisher: publisher)

    assert_equal 0, publisher.reopened
    assert_empty publisher.published
    assert_empty @master.marks
  end

  def test_a_timeout_without_the_channel_closed_leaves_it_pending
    run_sender([outgoing], publisher: FakePublisher.new(error: Timeout::Error))

    assert_empty @master.marks
    assert_equal 0, @publisher.reopened
  end

  # --- anomalia 5: republicar la oferta vigente tras la reconexion ---

  OUR_OFFER_ID = '12-cycle-7'.freeze

  OFFER_DATA = {
    'offer' => { 'offerId' => OUR_OFFER_ID, 'quantity' => 50, 'pricePerEnergy' => 0.2 },
    'offer-updated' => { 'offerId' => OUR_OFFER_ID, 'remaining' => 30, 'pricePerEnergy' => 0.2 },
    'offer-withdrawn' => { 'offerId' => OUR_OFFER_ID }
  }.freeze

  def offer_message(type = 'offer', changes = {})
    outgoing({ 'type' => type, 'data' => OFFER_DATA.fetch(type) }.merge(changes))
  end

  def status(cycle_id: 'cycle-7', last_offer_at: Time.now + 600)
    { 'type' => 'status-statement', 'cycleId' => cycle_id,
      'data' => { 'market' => { 'lastOfferAt' => last_offer_at.utc.iso8601 } } }
  end

  # publica la oferta por el outbox como siempre, y despues hay un corte
  def offer_sender_after_outage(published, status_message: status, limiter: nil)
    @offers = OfferMemory.new
    @offers.status_received(status_message)
    sender = build_sender(published.map { |message| [message, 'market', 'market.offer.12'] },
                          offers: @offers, limiter: limiter)
    sender.run_once
    @master = FakeMaster.new([])
    sender.instance_variable_set(:@master, @master)
    @publisher.published.clear
    sender.connection_recovered!
    sender
  end

  def test_after_the_recovery_the_current_offer_is_republished_with_the_same_idpk
    offer_sender_after_outage([offer_message]).run_once

    copy = @publisher.published.last
    assert_equal 1, @publisher.published.size
    assert_equal offer_message['idpk'], copy['idpk']
    refute_equal offer_message['msgId'], copy['msgId']
    assert_equal offer_message['data'], copy['data']
    assert_equal ['market', 'market.offer.12'], @publisher.destinations.last
    assert(@logs.any? { |line| line.include?('Oferta del ciclo cycle-7 republicada tras reconexión') })
    assert_empty @master.marks
  end

  def test_republishes_the_last_offer_updated
    updated = offer_message('offer-updated', 'msgId' => '44444444-4444-4444-8444-444444444444',
                                             'idpk' => '55555555-5555-4555-8555-555555555555')
    offer_sender_after_outage([offer_message, updated]).run_once

    assert_equal [updated['idpk']], @publisher.published.map { |message| message['idpk'] }
    assert_equal 'offer-updated', @publisher.published.last['type']
  end

  def test_republishes_only_once_per_recovery
    sender = offer_sender_after_outage([offer_message])
    3.times { sender.run_once }

    assert_equal 1, @publisher.published.size
  end

  def test_a_withdrawn_offer_is_not_republished
    withdrawn = offer_message('offer-withdrawn', 'msgId' => '44444444-4444-4444-8444-444444444444',
                                                 'idpk' => '55555555-5555-4555-8555-555555555555')
    offer_sender_after_outage([offer_message, withdrawn]).run_once

    assert_empty @publisher.published
    assert(@logs.any? { |line| line.include?('No hay oferta vigente') })
  end

  def test_an_offer_from_a_past_cycle_is_not_republished
    offer_sender_after_outage([offer_message]).tap { @offers.status_received(status(cycle_id: 'cycle-8')) }.run_once

    assert_empty @publisher.published
  end

  def test_an_offer_after_last_offer_at_is_not_republished
    offer_sender_after_outage([offer_message], status_message: status(last_offer_at: Time.now - 1)).run_once

    assert_empty @publisher.published
  end

  def test_without_a_recovery_nothing_is_republished
    sender = offer_sender_after_outage([offer_message])
    sender.instance_variable_set(:@republish_pending, false)
    sender.run_once

    assert_empty @publisher.published
  end

  def test_the_republished_offer_respects_the_limit_and_waits_for_quota
    clock = FakeClock.new
    limiter = RateLimiter.new(limit: 1, window: 60, clock: clock)
    sender = offer_sender_after_outage([offer_message], limiter: limiter)
    sender.run_once
    assert_empty @publisher.published

    clock.now = 60.0
    sender.run_once
    assert_equal [offer_message['idpk']], @publisher.published.map { |message| message['idpk'] }
  end

  def test_an_unconfirmed_republication_is_retried_in_the_next_round
    sender = offer_sender_after_outage([offer_message])
    @publisher.instance_variable_set(:@confirm, false)
    sender.run_once
    @publisher.instance_variable_set(:@confirm, true)
    sender.run_once

    assert_equal 2, @publisher.published.size
    assert_equal 1, @logs.count { |line| line.include?('republicada tras reconexión') }
  end
end
