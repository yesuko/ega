# What money is for: every user has the same four pots, each taking a share of
# every income.
Sequel.migration do
  change do
    create_table(:pots) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :kind, null: false # future, buy, living, enjoy
      String :name, null: false
      Integer :percent, null: false
      # Where this pot's money should live; money elsewhere is suggested as a move.
      foreign_key :home_account_id, :accounts, on_delete: :set_null
      Integer :position, null: false, default: 0
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      unique [:user_id, :kind]
    end
  end
end
