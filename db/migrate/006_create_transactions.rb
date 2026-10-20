# Every money event is one transactions row plus signed entries, one per pot
# and account it touches. Pot and account balances are sums of entries.
Sequel.migration do
  change do
    create_table(:transactions) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      # income, spend, move, shift, check, opening, invest, growth, cashout
      String :kind, null: false
      Date :occurred_on, null: false
      Bignum :amount, null: false # pesewas, always positive
      Bignum :fee, null: false, default: 0
      String :source # income: salary, client work, ...
      String :note
      # The transaction ID from a pasted MoMo/bank SMS, to warn about repeats.
      String :external_ref
      foreign_key :buy_item_id, :buy_items, on_delete: :set_null
      foreign_key :investment_id, :investments, on_delete: :cascade
      # The buy item or investment as it was before this event, so deleting
      # the event can put it back.
      String :snapshot, text: true
      DateTime :created_at, null: false

      index [:user_id, :occurred_on]
      index [:user_id, :external_ref]
    end

    create_table(:entries) do
      primary_key :id
      foreign_key :transaction_id, :transactions, null: false, on_delete: :cascade
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :pot_id, :pots, null: false
      foreign_key :account_id, :accounts, null: false
      Bignum :amount, null: false # pesewas, signed
      # income, spend, fee, move, shift, check, opening, invest, growth, cashout
      String :flow, null: false
      Date :occurred_on, null: false

      index [:user_id, :pot_id, :account_id]
      index [:user_id, :occurred_on]
      index :transaction_id
    end
  end
end
