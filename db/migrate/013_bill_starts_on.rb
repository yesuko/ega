# The first month a bill counts for. Set when a bill is added after its date
# has passed: "paid already" starts it next time, "still to pay" keeps this one.
Sequel.migration do
  change do
    alter_table(:bills) do
      add_column :starts_on, Date # first day of the first month counted; nil = not asked
    end
  end
end
