Sequel.migration do
  change do
    alter_table(:users) do
      add_column :show_money_quote, TrueClass, null: false, default: true
    end
  end
end
