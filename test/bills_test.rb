require 'test_helper'
require 'rack/test'
require File.expand_path('../app', __dir__)

class BillsPlanTest < Minitest::Test
  DAY = Date.new(2026, 10, 20)

  def setup
    @user = make_user
    @momo = account(@user, 'MoMo')
    @living = @user.pot('living')
    ledger(@user, DAY).opening([[@living, @momo, cedis(1000)]], on: DAY - 5)
    @rent = Bill.create(user_id: @user.id, name: 'Rent', amount: cedis(600), due_day: 1)
    @ecg = Bill.create(user_id: @user.id, name: 'ECG', amount: cedis(100), due_day: 28)
  end

  def pay(bill, amount, on: DAY, month: nil)
    p = Plan.new(@user, today: on)
    ledger(@user, on).spend(amount: cedis(amount), pot: @living, account: @momo, on: on, note: bill.name,
                            bill: bill, bill_month: month || p.bill_month_for(bill, on))
  end

  def test_unpaid_bills_this_month_are_due_and_overdue_ones_flagged
    due = plan(@user, DAY).bills_due
    assert_equal [['Rent', true], ['ECG', false]], due.map { |d| [d[:bill].name, d[:overdue]] }
    pay(@rent, 600)
    assert_equal ['ECG'], plan(@user, DAY).bills_due.map { |d| d[:bill].name }
  end

  def test_next_months_bills_count_when_due_before_the_next_income
    pay(@rent, 600)
    pay(@ecg, 100)
    assert_empty plan(@user, DAY).bills_due # irregular income: next income is 1 Nov
    @user.update(payday: 25)
    @user.refresh
    after_payday = Date.new(2026, 10, 26) # next income 25 Nov, so 1 Nov rent is due first
    assert_equal [['Rent', Date.new(2026, 11, 1)]], plan(@user, after_payday).bills_due.map { |d| [d[:bill].name, d[:month]] }
    assert_equal Date.new(2026, 11, 1), plan(@user, after_payday).bill_month_for(@rent, after_payday)
  end

  def test_living_today_keeps_bills_back_and_ignores_bill_payments
    today = plan(@user, DAY).living_today # 1000 - (600 + 100) kept = 300 free over 12 days to 1 Nov
    assert_equal [cedis(700), cedis(300), cedis(25), 12], today.values_at(:kept, :free, :allowance, :days)

    ledger(@user, DAY).spend(amount: cedis(10), pot: @living, account: @momo, on: DAY, note: 'Trotro')
    pay(@rent, 600)
    today = plan(@user, DAY).living_today
    assert_equal [cedis(100), cedis(10), cedis(25), cedis(15)], today.values_at(:kept, :spent, :allowance, :left)
  end

  def test_pot_for_payee_suggests_the_last_pot_used
    p = plan(@user, DAY)
    assert_nil p.pot_for_payee('JOYCE OBERKO')
    ledger(@user, DAY).spend(amount: cedis(70), pot: @user.pot('enjoy'), account: @momo, on: DAY, payee: 'JOYCE OBERKO')
    ledger(@user, DAY).spend(amount: cedis(50), pot: @living, account: @momo, on: DAY, payee: 'Joyce Oberko')
    assert_equal 'living', plan(@user, DAY).pot_for_payee(' joyce oberko ').kind
  end
end

class BillsAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    post '/signup', { name: 'Ama', email: 'ama@example.com', password: 'password123', confirm: 'password123' }, 'REMOTE_ADDR' => '10.0.0.1'
    @user = User.first(email: 'ama@example.com')
    @momo = @user.accounts.find { |a| a.name == 'MoMo' }
  end

  def test_adding_and_paying_a_bill
    post '/bills', name: 'Rent', amount: '600', due_day: '1', passed: 'due' # the 1st has passed: still to pay
    bill = Bill.first(user_id: @user.id)
    assert_equal ['Rent', 60_000, 1], [bill.name, bill.amount, bill.due_day]
    get '/'
    assert_includes last_response.body, 'needs GH₵ 600 more to cover your bills'
    post '/income', amount: '2000', account_id: @momo.id, mode: 'split', occurred_on: Date.today.iso8601 # Living 1,000
    get '/'
    assert_includes last_response.body, 'kept back for 1 bill'

    post '/spend', amount: '600', pot_id: @user.pot('enjoy').id, bill_id: bill.id, account_id: @momo.id, occurred_on: Date.today.iso8601
    txn = Transaction.where(user_id: @user.id).last
    assert_equal [bill.id, Date.new(Date.today.year, Date.today.month, 1)], [txn.bill_id, txn.bill_month]
    assert_equal @user.pot('living').id, txn.entries.first.pot_id # a bill always comes from Living
    assert_empty Plan.new(User[@user.id]).bills_due.select { |d| d[:month].month == Date.today.month }
  end

  def test_money_out_defaults_to_living_or_the_payees_last_pot
    get '/spend/new'
    assert_match(/name="pot_id" value="#{@user.pot('living').id}" checked/, last_response.body)
    post '/spend', amount: '20', pot_id: @user.pot('enjoy').id, account_id: @momo.id, occurred_on: Date.today.iso8601, payee: 'KFC ACCRA'
    get '/spend/new?payee=KFC+ACCRA'
    assert_match(/name="pot_id" value="#{@user.pot('enjoy').id}" checked/, last_response.body)
  end

  def test_inbox_suggests_the_pot_used_last_time_for_that_payee
    post '/inbox/token'
    token = User[@user.id].inbox_token
    post "/sms/#{token}", text: 'Payment made for GHS 70.00 to JOYCE OBERKO. Current Balance: GHS 900.00. Transaction ID: 51000000001.'
    first = InboxMessage.first
    post "/inbox/#{first.id}/record", as: 'out', account_id: @momo.id, pot_id: @user.pot('living').id
    assert_equal 'JOYCE OBERKO', Transaction[first.refresh.transaction_id].payee

    post "/sms/#{token}", text: 'Payment made for GHS 45.00 to JOYCE OBERKO. Current Balance: GHS 855.00. Transaction ID: 51000000002.'
    get '/inbox'
    assert_includes last_response.body, '(last time: Living)'
  end

  def test_wrong_pot_moves_a_spend_and_can_mark_a_bill
    post '/bills', name: 'DSTV', amount: '150'
    bill = Bill.first(user_id: @user.id)
    post '/spend', amount: '70', pot_id: @user.pot('enjoy').id, account_id: @momo.id, occurred_on: Date.today.iso8601, note: 'Food'
    txn = Transaction.where(user_id: @user.id).last

    post "/transactions/#{txn.id}/pot", pot_id: @user.pot('living').id
    assert_equal @user.pot('living').id, txn.refresh.entries.first.pot_id
    assert_equal(-cedis(70), Plan.new(User[@user.id]).pot_balance(@user.pot('living')))
    assert_equal 0, Plan.new(User[@user.id]).pot_balance(@user.pot('enjoy'))

    post "/transactions/#{txn.id}/pot", pot_id: @user.pot('living').id, bill_id: bill.id
    assert_equal bill.id, txn.refresh.bill_id
    post "/transactions/#{txn.id}/pot", pot_id: @user.pot('enjoy').id
    assert_equal [nil, nil], [txn.refresh.bill_id, txn.bill_month]
  end

  def test_income_cant_change_pot_and_removing_a_paid_bill_keeps_it
    post '/income', amount: '100', account_id: @momo.id, mode: 'split', occurred_on: Date.today.iso8601
    income = Transaction.where(user_id: @user.id, kind: 'income').last
    post "/transactions/#{income.id}/pot", pot_id: @user.pot('enjoy').id
    assert_equal 4, income.refresh.entries.size

    post '/bills', name: 'Water', amount: '40'
    bill = Bill.first(user_id: @user.id)
    post '/spend', amount: '40', pot_id: @user.pot('living').id, bill_id: bill.id, account_id: @momo.id, occurred_on: Date.today.iso8601
    post "/bills/#{bill.id}/delete"
    assert_equal false, bill.refresh.active
    get '/bills'
    refute_includes last_response.body, 'class="name">Water'
  end
end

class BillRepeatsTest < Minitest::Test
  DAY = Date.new(2026, 10, 20)

  def setup
    @user = make_user
    @momo = account(@user, 'MoMo')
    @living = @user.pot('living')
    ledger(@user, DAY).opening([[@living, @momo, cedis(5000)]], on: Date.new(2026, 10, 1))
    @fees = Bill.create(user_id: @user.id, name: 'School fees', amount: cedis(3000), repeats: 'termly',
                        pay_by: Date.new(2027, 1, 12), created_at: Time.new(2026, 10, 20))
  end

  def pay(bill, on)
    month = plan(@user, on).bill_month_for(bill, on)
    ledger(@user, on).spend(amount: bill.amount, pot: @living, account: @momo, on: on, note: bill.name, bill: bill, bill_month: month)
  end

  def saving(on)
    plan(@user, on).bill_savings.find { |s| s[:bill].id == @fees.id }
  end

  def test_term_dates_run_every_four_months_from_the_pay_by_date
    assert_equal [Date.new(2027, 1, 12), Date.new(2027, 5, 12)], @fees.dates_from(DAY).first(2)
    assert_equal [Date.new(2027, 1, 12), Date.new(2027, 5, 12)], @fees.dates_from(Date.new(2027, 3, 1)).first(2)
    assert_equal Date.new(2026, 9, 12), @fees.date_before(Date.new(2027, 1, 12))
  end

  def test_a_term_bill_is_set_aside_from_each_income_until_it_is_due
    # Irregular income: incomes are expected on 1 Nov, 1 Dec and 1 Jan, so a third each time.
    assert_equal [0, cedis(1000), Date.new(2026, 11, 1), cedis(1000)], saving(DAY).values_at(:kept, :per_income, :next_on, :next_share)
    assert_equal cedis(1000), saving(Date.new(2026, 11, 1))[:kept]
    assert_equal cedis(2000), saving(Date.new(2026, 12, 15))[:kept]
    assert_equal cedis(2000), plan(@user, Date.new(2026, 12, 15)).living_today[:kept]

    january = plan(@user, Date.new(2027, 1, 2))
    assert_nil saving(Date.new(2027, 1, 2))
    assert_equal [[@fees.id, Date.new(2027, 1, 12)]], january.bills_due.map { |d| [d[:bill].id, d[:due_on]] }
    assert_equal cedis(3000), january.living_today[:kept]
  end

  def test_paying_moves_it_to_the_next_term_at_a_quarter_a_month
    pay(@fees, Date.new(2027, 1, 5))
    assert_equal Date.new(2027, 1, 1), Transaction.where(bill_id: @fees.id).get(:bill_month)
    after = plan(@user, Date.new(2027, 1, 6))
    assert_empty after.bills_due
    assert_equal Date.new(2027, 5, 12), after.bill_date(@fees)
    assert_equal [0, cedis(750)], saving(Date.new(2027, 1, 6)).values_at(:kept, :per_income) # Feb, Mar, Apr, May
    assert_equal cedis(1500), saving(Date.new(2027, 3, 1))[:kept]
  end

  def test_an_unpaid_term_stays_overdue_until_the_next_one_is_due
    late = plan(@user, Date.new(2027, 2, 3))
    assert_equal [[Date.new(2027, 1, 12), true]], late.bills_due.map { |d| d.values_at(:due_on, :overdue) }
    assert_equal Date.new(2027, 1, 1), late.bill_month_for(@fees, Date.new(2027, 2, 3))
    assert_equal Date.new(2027, 5, 12), plan(@user, Date.new(2027, 5, 13)).bills_due.first[:due_on]
  end

  def test_a_paid_one_off_is_done
    fridge = Bill.create(user_id: @user.id, name: 'Fridge repair', amount: cedis(400), repeats: 'once',
                         pay_by: Date.new(2026, 11, 15), created_at: Time.new(2026, 10, 20))
    assert_equal cedis(400), plan(@user, DAY).bill_savings.find { |s| s[:bill].id == fridge.id }[:per_income]
    assert(plan(@user, Date.new(2026, 11, 2)).bills_due.any? { |d| d[:bill].id == fridge.id })
    pay(fridge, Date.new(2026, 11, 2))
    done = plan(@user, Date.new(2026, 11, 3))
    assert_nil done.bill_date(fridge)
    refute(done.bills_due.any? { |d| d[:bill].id == fridge.id })
    assert_equal Date.new(2026, 11, 2), done.bills_paid[fridge.id].occurred_on
  end

  def test_with_a_payday_the_shares_come_on_paydays
    @user.update(payday: 25)
    assert_equal 0, saving(DAY)[:kept] # paydays 25 Oct, 25 Nov, 25 Dec
    assert_equal cedis(1000), saving(Date.new(2026, 10, 26))[:kept]
    assert_equal [Date.new(2027, 1, 12)], plan(@user, Date.new(2026, 12, 26)).bills_due.map { |d| d[:due_on] }
  end

  def test_bills_monthly_spreads_terms_and_years
    Bill.create(user_id: @user.id, name: 'Rent', amount: cedis(600), due_day: 1)
    Bill.create(user_id: @user.id, name: 'Licence', amount: cedis(1200), repeats: 'yearly', pay_by: Date.new(2027, 6, 1))
    assert_equal cedis(600 + 750 + 100), plan(@user, DAY).bills_monthly
  end
end

class BillRepeatsAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    post '/signup', { name: 'Ama', email: 'ama@example.com', password: 'password123', confirm: 'password123' }, 'REMOTE_ADDR' => '10.0.0.1'
    @user = User.first(email: 'ama@example.com')
    @momo = @user.accounts.find { |a| a.name == 'MoMo' }
  end

  def test_adding_a_term_bill_needs_a_pay_by_date
    post '/bills', name: 'School fees', amount: '3000', repeats: 'termly', due_day: '5'
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'Pay by date is needed'

    pay_by = Date.today >> 3
    post '/bills', name: 'School fees', amount: '3000', repeats: 'termly', due_day: '5', pay_by: pay_by.iso8601
    bill = Bill.first(user_id: @user.id)
    assert_equal ['termly', pay_by, nil], [bill.repeats, bill.pay_by, bill.due_day]
    follow_redirect!
    assert_includes last_response.body, 'Living sets aside about'

    get "/bills/#{bill.id}/edit"
    assert_includes last_response.body, %(value="#{pay_by.iso8601}")
    assert_match(/value="termly" checked/, last_response.body)
  end

  def test_a_one_off_due_after_one_income_is_kept_back_from_then
    first = Date.new(Date.today.year, Date.today.month, -1) + 1
    post '/bills', name: 'Fridge repair', amount: '450', repeats: 'once', pay_by: (first + 5).iso8601
    follow_redirect!
    label = first.strftime(first.year == Date.today.year ? '%-d %b' : '%-d %b %Y')
    assert_includes last_response.body, "Living keeps GH₵ 450 back for it from #{label}"
  end

  def test_a_monthly_bill_ignores_a_pay_by_date
    post '/bills', name: 'Rent', amount: '600', repeats: 'monthly', due_day: '1', pay_by: Date.today.iso8601, passed: 'due'
    bill = Bill.first(user_id: @user.id)
    assert_equal ['monthly', 1, nil], [bill.repeats, bill.due_day, bill.pay_by]
  end

  def test_bills_page_warns_when_living_gets_less_than_the_bills_need
    post '/income', amount: '1000', account_id: @momo.id, mode: 'split', occurred_on: (Date.today - 20).iso8601 # Living 500
    post '/bills', name: 'Rent', amount: '1000', due_day: '1', passed: 'due' # asked when the 1st was before the first record
    get '/bills'
    assert_includes last_response.body, 'Your bills need about GH₵ 1,000 a month, but Living gets about GH₵ 714'
  end

  def test_saving_starting_balances_again_replaces_them
    living = @user.pot('living')
    2.times { post '/setup', balances: { @momo.id.to_s => { living.id.to_s => '500' } } }
    assert_equal 1, Transaction.where(user_id: @user.id, kind: 'opening').count
    assert_equal cedis(500), Plan.new(User[@user.id]).total

    get '/setup'
    assert_includes last_response.body, %(name="balances[#{@momo.id}][#{living.id}]" value="500.00")
    assert_includes last_response.body, 'replaced, not added to'

    post '/setup', balances: { @momo.id.to_s => { living.id.to_s => '' } }
    assert_equal 0, Plan.new(User[@user.id]).total
    post '/setup', balances: {}
    assert_equal 422, last_response.status
  end
end

class BillPassedTest < Minitest::Test
  TODAY = Date.new(2026, 10, 21)

  def setup
    @user = make_user
    momo = account(@user, 'MoMo')
    ledger(@user, TODAY).opening([[@user.pot('living'), momo, cedis(2000)]], on: Date.new(2026, 10, 20)) # started 20 Oct
  end

  def passed(**attributes)
    plan(@user, TODAY).bill_passed_unrecorded(Bill.new({ user_id: @user.id, name: 'Bella', amount: cedis(1000), repeats: 'monthly' }.merge(attributes)))
  end

  def test_asks_when_the_date_passed_before_the_first_record
    assert_equal({ date: Date.new(2026, 10, 1), next: Date.new(2026, 11, 1) }, passed(due_day: 1))
    assert_nil passed(due_day: 25) # still ahead this month
    assert_nil passed(due_day: 20) # on or after the first record: the payment should be recorded
    assert_nil passed(due_day: 1, starts_on: Date.new(2026, 10, 1)) # already answered
    assert_nil passed(repeats: 'once', pay_by: Date.new(2026, 10, 5))
    assert_equal({ date: Date.new(2026, 9, 12), next: Date.new(2027, 1, 12) }, passed(repeats: 'termly', pay_by: Date.new(2026, 9, 12)))
  end

  def test_a_bill_starting_next_month_keeps_nothing_back_now
    Bill.create(user_id: @user.id, name: 'Bella', amount: cedis(1000), due_day: 1, starts_on: Date.new(2026, 11, 1))
    today = plan(@user, TODAY)
    assert_empty today.bills_due
    assert_equal 0, today.living_today[:kept]
  end
end

class BillPassedAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    skip 'needs a day earlier this month' if Date.today.day == 1
    post '/signup', { name: 'Ama', email: 'ama@example.com', password: 'password123', confirm: 'password123' }, 'REMOTE_ADDR' => '10.0.0.1'
    @user = User.first(email: 'ama@example.com')
    @yesterday = (Date.today - 1).day
    @this_month = Date.new(Date.today.year, Date.today.month, 1)
  end

  def test_adding_a_bill_whose_day_passed_asks_if_it_was_paid
    post '/bills', name: 'Bella Allowance', amount: '1000', repeats: 'monthly', due_day: @yesterday.to_s
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'paid already?'
    assert_includes last_response.body, 'name="passed" value="paid"'
    assert_nil Bill.first(user_id: @user.id)

    post '/bills', name: 'Bella Allowance', amount: '1000', repeats: 'monthly', due_day: @yesterday.to_s, passed: 'paid'
    bill = Bill.first(user_id: @user.id)
    assert_equal @this_month >> 1, bill.starts_on
    assert_empty Plan.new(User[@user.id]).bills_due
    follow_redirect!
    assert_includes last_response.body, 'It starts from'
  end

  def test_still_to_pay_keeps_it_overdue
    post '/bills', name: 'Rent', amount: '600', due_day: @yesterday.to_s, passed: 'due'
    bill = Bill.first(user_id: @user.id)
    assert_equal @this_month, bill.starts_on
    assert(Plan.new(User[@user.id]).bills_due.first[:overdue])
  end

  def test_after_the_first_record_it_is_not_asked_and_points_to_linking_a_spend
    momo = @user.accounts.find { |a| a.name == 'MoMo' }
    post '/income', amount: '500', account_id: momo.id, mode: 'split', occurred_on: (Date.today - 20).iso8601
    post '/bills', name: 'Rent', amount: '600', due_day: @yesterday.to_s
    assert_equal 302, last_response.status
    get '/bills'
    assert_includes last_response.body, 'Already recorded it? Open that spend and choose this bill.'
  end

  def test_saving_an_overdue_bill_from_before_asks_too
    bill = Bill.create(user_id: @user.id, name: 'Bella Allowance', amount: cedis(1000), due_day: @yesterday)
    post "/bills/#{bill.id}", name: bill.name, amount: '1000', repeats: 'monthly', due_day: @yesterday.to_s
    assert_includes last_response.body, 'paid already?'
    post "/bills/#{bill.id}", name: bill.name, amount: '1000', repeats: 'monthly', due_day: @yesterday.to_s, passed: 'paid'
    assert_equal @this_month >> 1, bill.refresh.starts_on
  end
end
