Sequel.migration do
  change do
    create_table(:buy_items) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :name, null: false
      Bignum :price, null: false # pesewas
      Date :target_on
      String :note
      Integer :position, null: false, default: 0
      String :status, null: false # cooling, listed, bought, dropped
      DateTime :cooling_until
      Date :bought_on
      Bignum :paid
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:user_id, :status]
    end
  end
end
