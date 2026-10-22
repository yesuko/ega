# Monthly bills paid from Living (rent, electricity, DSTV, ...). A spend that
# pays one carries bill_id and the month it pays for; Living keeps back what
# unpaid bills need, and spreads the rest as "Living today".
# Spends also remember who was paid (payee), so the next payment to the same
# payee suggests the same pot.
Sequel.migration do
  up do
    create_table(:bills) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :name, null: false
      Bignum :amount, null: false # pesewas, what it usually costs
      Integer :due_day # 1-31; nil = any time in the month
      TrueClass :active, null: false, default: true
      Integer :position, null: false, default: 0
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:user_id, :active]
    end

    alter_table(:transactions) do
      add_foreign_key :bill_id, :bills, on_delete: :set_null
      add_column :bill_month, Date # first day of the month the payment is for
      add_column :payee, String
      add_index [:user_id, :bill_id]
    end

    # Payees for spends already saved from SMS, so the suggestion starts working now.
    from(:inbox_messages).exclude(transaction_id: nil).exclude(counterparty: nil).each do |message|
      from(:transactions).where(id: message[:transaction_id], kind: 'spend').update(payee: message[:counterparty])
    end
  end

  down do
    alter_table(:transactions) do
      drop_index [:user_id, :bill_id]
      drop_foreign_key :bill_id
      drop_column :bill_month
      drop_column :payee
    end
    drop_table(:bills)
  end
end
