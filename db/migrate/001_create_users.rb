Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :name, null: false
      String :email, null: false, unique: true
      String :password_digest, null: false
      # Day of the month income usually arrives; nil = irregular, plan to month end.
      Integer :payday
      Integer :emergency_months, null: false, default: 3
      # Monthly living costs in pesewas; nil = use the average of recent months.
      Bignum :living_target
      Integer :cooling_hours, null: false, default: 48
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end
