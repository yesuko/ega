class Entry < Sequel::Model
  many_to_one :txn, class: :Transaction, key: :transaction_id
  many_to_one :pot
  many_to_one :account

  # Flows that count as spending in reports.
  SPENDING = %w[spend fee].freeze

  def negative?
    amount.negative?
  end
end
