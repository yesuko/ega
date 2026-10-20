# Where money physically sits: a bank account, a MoMo wallet, cash on hand, or
# the one "Investments" account per user that holds what is invested.
Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :name, null: false
      String :kind, null: false # bank, momo, cash, investment
      Integer :position, null: false, default: 0
      DateTime :archived_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :user_id
    end
  end
end
