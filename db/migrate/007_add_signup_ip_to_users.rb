# Where each account was created from, to cap sign-ups per address.
Sequel.migration do
  change do
    alter_table(:users) do
      add_column :signup_ip, String
      add_index :signup_ip
    end
  end
end
