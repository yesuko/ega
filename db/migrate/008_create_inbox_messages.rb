# Money SMS forwarded from a phone (MacroDroid on Android, Shortcuts on
# iPhone) to the user's private inbox link, waiting to be confirmed.
Sequel.migration do
  change do
    alter_table(:users) do
      add_column :inbox_token, String
      add_index :inbox_token, unique: true
    end

    create_table(:inbox_messages) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :body, text: true, null: false
      String :sender
      String :direction # in, out, or nil when the SMS doesn't say
      Bignum :amount, null: false # pesewas
      Bignum :fee, null: false, default: 0
      Bignum :balance
      String :counterparty
      String :detail # the SMS's reference or description
      String :ref_id # the transaction ID in the SMS
      String :network
      String :account_kind # momo or bank, guessed from the wording
      Date :occurred_on, null: false
      String :status, null: false, default: 'pending' # pending, recorded, dismissed
      foreign_key :transaction_id, :transactions, on_delete: :set_null
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:user_id, :status]
      index [:user_id, :ref_id]
    end
  end
end
