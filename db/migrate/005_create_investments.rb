Sequel.migration do
  change do
    create_table(:investments) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :kind, null: false # tbill, bond, fund, stock, pension, deposit, other
      String :name, null: false
      String :provider
      Bignum :principal, null: false # pesewas put in, less what was withdrawn
      Bignum :value, null: false # pesewas it is worth now
      BigDecimal :rate, size: [7, 3] # yearly %, when known
      Date :started_on, null: false
      Date :matures_on
      # Can be withdrawn within days (e.g. a money market fund), so it counts
      # towards the emergency fund.
      TrueClass :emergency, null: false, default: false
      String :status, null: false, default: 'active' # active, closed
      Date :closed_on
      String :note
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:user_id, :status]
    end
  end
end
