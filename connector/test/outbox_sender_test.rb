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

    def pending_outbox
      @pending
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

    def publish_confirmed(message)
      raise @error if @error

      @published << message
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

  def run_sender(payloads, publisher: FakePublisher.new, mark_status: 200)
    pending = payloads.each_with_index.map { |payload, index| { 'id' => index + 1, 'payload' => payload } }
    @master = FakeMaster.new(pending, mark_status: mark_status)
    @publisher = publisher
    @logs = []
    OutboxSender.new(master: @master, publisher: publisher, city_id: '12', log: ->(text) { @logs << text }).run_once
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
end
