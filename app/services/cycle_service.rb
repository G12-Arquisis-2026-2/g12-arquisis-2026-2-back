class CycleService
  # Tiempos del enunciado: ciclos de 2 h, ventana de negociación de 20 min que termina en el
  # validUntil del status-statement, y el reporte se acepta solo en sus últimos 5 min.
  # Configurables porque la duración del periodo de cierre es "un valor configurado del despliegue".
  CYCLE_LENGTH = ENV.fetch("CYCLE_LENGTH_MINUTES", 120).to_i.minutes
  NEGOTIATION_WINDOW = ENV.fetch("NEGOTIATION_WINDOW_MINUTES", 20).to_i.minutes
  REPORT_PERIOD = ENV.fetch("REPORT_PERIOD_MINUTES", 5).to_i.minutes

  # Se espera este rato a que la central mande sola el status-statement antes de pedirlo.
  STATUS_GRACE = 1.minute
  # Hasta 3 peticiones por ventana: la 2ª 1 min después de la 1ª, la 3ª 3 min después de la 2ª.
  # Política de abuso del curso: nunca más que esto.
  REQUEST_RETRY_DELAYS = [1.minute, 3.minutes].freeze
  MAX_REQUESTS = REQUEST_RETRY_DELAYS.size + 1
  # No se encola un reporte si quedan menos de esto para el cierre (CYCLE_EXPIRED cuesta la multa).
  LATE_MARGIN = 30.seconds
  # El outbox no publica un reporte si quedan menos de esto (ver OutboxMessage.expire_late_reports!).
  PUBLISH_MARGIN = 5.seconds
  # Durante el periodo de cierre se revisa seguido por si el ledger cambió y hay que corregir.
  REPORT_TICK = 30.seconds
  # Nunca se duerme más que esto: un status-statement puede llegar antes de lo esperado.
  MAX_SLEEP = 1.minute

  # Solicitud directa a la central (§ Peticiones directas). ask: "status-statement" o "distance-table".
  def self.build_direct_request(ask:)
    {
      idpk: SecureRandom.uuid,
      msgId: SecureRandom.uuid,
      type: "request",
      cityId: ENV.fetch('CITY_ID', 'TK3'),
      data: {
        ask: ask,
      },
      timestamp: Time.current.iso8601
    }
  end

  # Construcción del reporte final de balance energético y presupuesto del ciclo.
  # idpk nuevo por cada corrección; un reintento del mismo reporte pasa el idpk anterior.
  def self.build_negotiation_report(cycle_id:, budget_balance:, energy_balance:, idpk: SecureRandom.uuid)
    {
      idpk: idpk,
      msgId: SecureRandom.uuid,
      type: "negotiation-report",
      cityId: ENV.fetch('CITY_ID', 'TK3'),
      cycleId: cycle_id,
      data: {
        budgetBalance: budget_balance,
        energyBalance: energy_balance
      },
      timestamp: Time.current.iso8601
    }
  end

  # Revisa el estado guardado y hace lo que toque. Todo sale del estado en la BD, así que
  # correrlo de más (o en dos cadenas a la vez) no repite envíos. Devuelve cuándo volver a revisar.
  def self.tick(now = Time.current)
    mark_missed_reports(now)
    cycle = Cycle.where.not(valid_until: nil).order(valid_until: :desc).first

    wakes = [now + MAX_SLEEP, status_step(cycle, now)]
    wakes << report_step(cycle, now) if cycle
    wakes << request_if_due("distance-table", since: now - CYCLE_LENGTH, now: now) unless DistanceTable.exists?
    wakes.compact.min
  end

  # La central respondió error REPORT_TOO_EARLY a nuestro reporte (data.target = su msgId).
  def self.report_too_early!(target, opens_at)
    cycle = Cycle.find_by(report_msg_id: target) if target.present?
    return Rails.logger.warn("[CycleService] REPORT_TOO_EARLY para un reporte desconocido (#{target})") unless cycle

    cycle.update!(report_not_before: Time.iso8601(opens_at.to_s))
  rescue ArgumentError
    Rails.logger.warn("[CycleService] REPORT_TOO_EARLY con opensAt inválido: #{opens_at.inspect}")
  end

  # Pide el status-statement si la ventana esperada abrió y no llegó. Sin ciclos (arranque en frío)
  # se pide de inmediato. Máximo MAX_REQUESTS por ventana (o por CYCLE_LENGTH sin ciclos).
  def self.status_step(cycle, now)
    return request_if_due("status-statement", since: now - CYCLE_LENGTH, now: now) if cycle.nil?

    first_open = cycle.valid_until + CYCLE_LENGTH - NEGOTIATION_WINDOW
    return first_open + STATUS_GRACE if now < first_open + STATUS_GRACE

    # Si una ventana pasa entera sin status-statement, se espera la siguiente (ese ciclo no se reporta).
    open = first_open + ((now - first_open) / CYCLE_LENGTH.to_i).floor * CYCLE_LENGTH
    next_open = open + CYCLE_LENGTH + STATUS_GRACE
    return next_open if now >= open + NEGOTIATION_WINDOW
    return open + STATUS_GRACE if now < open + STATUS_GRACE

    request_if_due("status-statement", since: open, now: now) || next_open
  end

  # Publica una petición si toca. Devuelve cuándo toca la siguiente, o nil si ya no quedan intentos.
  # El registro de lo pedido son los mismos mensajes del outbox.
  def self.request_if_due(ask, since:, now:)
    sent = OutboxMessage.where(message_type: "request")
                        .where("payload -> 'data' ->> 'ask' = ?", ask)
                        .where(created_at: since..)
                        .order(:created_at).pluck(:created_at)
    return if sent.size >= MAX_REQUESTS

    due = sent.empty? ? now : sent.last + REQUEST_RETRY_DELAYS[sent.size - 1]
    return due if now < due

    Rails.logger.info "[CycleService] Pidiendo #{ask} a la central (intento #{sent.size + 1}/#{MAX_REQUESTS})"
    RabbitMQPublisher.publish(build_direct_request(ask: ask))
    attempts = sent.size + 1
    now + REQUEST_RETRY_DELAYS[attempts - 1] if attempts < MAX_REQUESTS
  end

  # Reporte solo en [validUntil - REPORT_PERIOD, validUntil - LATE_MARGIN), nunca tarde.
  def self.report_step(cycle, now)
    closes_at = cycle.valid_until
    opens_at = closes_at - REPORT_PERIOD
    return if cycle.report_missed_at || now >= closes_at - LATE_MARGIN
    return opens_at if now < opens_at
    return cycle.report_not_before if cycle.report_not_before && now < cycle.report_not_before

    send_report(cycle)
    now + REPORT_TICK
  end

  def self.send_report(cycle)
    balances = CycleBalanceService.call(cycle)
    changed = !cycle.report_sent? ||
              balances[:budget] != cycle.reported_budget || balances[:energy] != cycle.reported_energy
    retrying = cycle.report_not_before.present?
    return unless changed || retrying

    # Primer envío o corrección: idpk nuevo. Reintento del mismo contenido: mismo idpk.
    idpk = changed ? SecureRandom.uuid : cycle.report_idpk
    payload = build_negotiation_report(
      cycle_id: cycle.cycle_id, budget_balance: balances[:budget], energy_balance: balances[:energy], idpk: idpk
    )
    msg_id = RabbitMQPublisher.publish(payload, idpk: idpk)
    Rails.logger.info "[CycleService] negotiation-report del ciclo #{cycle.cycle_id} encolado (#{msg_id})"

    cycle.update!(report_sent: true, report_idpk: idpk, report_msg_id: msg_id, report_not_before: nil,
                  reported_budget: balances[:budget], reported_energy: balances[:energy])
  end

  # Ciclos recién cerrados sin un reporte publicado: no se envía nada, solo queda registro.
  def self.mark_missed_reports(now)
    Cycle.where(report_missed_at: nil, valid_until: (now - CYCLE_LENGTH)..now).find_each do |cycle|
      next if report_delivered?(cycle)

      cycle.update!(report_missed_at: now)
      AuditLog.create!(
        idpk: cycle.report_idpk,
        event_type: "REPORT_MISSED",
        reason: "La ventana del ciclo #{cycle.cycle_id} cerró sin negotiation-report entregado",
        raw_payload: { "cycleId" => cycle.cycle_id, "validUntil" => cycle.valid_until.iso8601 }
      )
    end
  end

  # Entregado = algún reporte del ciclo salió, y la central no lo rechazó por temprano.
  def self.report_delivered?(cycle)
    return false if cycle.report_not_before.present?

    OutboxMessage.where(message_type: "negotiation-report", status: "sent")
                 .where("payload ->> 'cycleId' = ?", cycle.cycle_id).exists?
  end

  private_class_method :status_step, :request_if_due, :report_step, :send_report,
                       :mark_missed_reports, :report_delivered?
end
