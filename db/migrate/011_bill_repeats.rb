# Bills that don't come every month: school fees each term, a yearly licence,
# a one-off. They have a pay-by date instead of a day of the month, and Living
# sets their money aside a share at a time until then.
Sequel.migration do
  change do
    alter_table(:bills) do
      add_column :repeats, String, null: false, default: 'monthly' # monthly, termly, yearly, once
      add_column :pay_by, Date # when not monthly: the pay-by date, the next one as last set
    end
  end
end
