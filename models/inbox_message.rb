class InboxMessage < Sequel::Model
  many_to_one :user
  many_to_one :txn, class: :Transaction, key: :transaction_id

  dataset_module do
    def pending
      where(status: 'pending').order(:occurred_on, :id)
    end

    def done
      exclude(status: 'pending').order(Sequel.desc(:updated_at))
    end
  end

  # A pending message for this SMS text, or nil when the text has no amount
  # (not a money SMS), so nothing else a phone forwards is ever stored.
  def self.from_sms(user, text, sender: nil, today: Date.today)
    sms = SmsParser.parse(text, today: today)
    return nil unless sms[:amount]&.positive?

    new(user_id: user.id, body: text, sender: sender, direction: sms[:direction]&.to_s, amount: sms[:amount],
        fee: sms[:fee], balance: sms[:balance], counterparty: sms[:counterparty],
        detail: sms[:reference] || sms[:description], ref_id: sms[:ref_id], network: sms.dig(:network, :name),
        account_kind: sms.dig(:network, :kind), occurred_on: sms[:on] || today, status: 'pending')
  end

  def before_create
    self.created_at ||= Time.now
    self.updated_at ||= Time.now
    super
  end

  def before_update
    self.updated_at = Time.now
    super
  end

  def money_in?
    direction == 'in'
  end

  def money_out?
    direction == 'out'
  end

  # Spending includes the fee the network charged.
  def spent
    amount + fee
  end

  def notes
    SmsParser.notes(counterparty: counterparty, detail: detail, fee: fee)
  end

  # An entry already saved with the same transaction ID (e.g. pasted by hand).
  def saved_already
    ref_id && Transaction.where(user_id: user_id, external_ref: ref_id).first
  end
end
