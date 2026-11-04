require 'minitest/autorun'
require_relative '../lib/master_client'
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
    attr_reader :published

    def initialize(confirm: true, error: nil)
      @confirm = confirm
      @error = error
      @published = []
    end

    attr_reader :destinations

    def publish_confirmed(message, exchange: nil, routing_key: nil)
      raise @error if @error

      @published << message
      (@destinations ||= []) << [exchange, routing_key]
      @confirm
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
  def build_sender(payloads, publisher: FakePublisher.new, mark_status: 200, enabled: true, limiter: nil)
    pending = payloads.each_with_index.map do |item, index|
      payload, exchange, routing_key = item.is_a?(Array) ? item : [item]
      { 'id' => index + 1, 'payload' => payload, 'exchange' => exchange, 'routing_key' => routing_key }
    end
    @master = FakeMaster.new(pending, mark_status: mark_status)
    @publisher = publisher
    @logs = []
    options = { master: @master, publisher: publisher, city_id: '12', log: ->(text) { @logs << text },
                enabled: enabled }
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
end
