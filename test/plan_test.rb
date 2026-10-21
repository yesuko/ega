require 'test_helper'

class PlanTest < Minitest::Test
  def setup
    @user = make_user
    @momo = account(@user, 'MoMo')
    @bank = account(@user, 'Bank savings')
  end

  def test_new_users_get_the_default_accounts_and_pots
    assert_equal ['Bank savings', 'MoMo', 'Cash', 'Investments'], @user.accounts.map(&:name)
    assert_equal [['future', 20], ['buy', 10], ['living', 50], ['enjoy', 20]], @user.pots.map { |p| [p.kind, p.percent] }
    assert_equal @bank.id, @user.pot('future').home_account_id
    assert_nil @user.pot('living').home_account_id
  end

  def test_split_shares_by_percent
    parts = plan(@user).split(cedis(1000))[:parts].transform_keys(&:kind)
    assert_equal({ 'future' => cedis(200), 'buy' => cedis(100), 'living' => cedis(500), 'enjoy' => cedis(200) }, parts)
  end

  def test_split_gives_rounding_pesewas_to_future_me
    parts = plan(@user).split(3)[:parts].transform_keys(&:kind)
    assert_equal 3, parts.values.sum
    assert_equal 2, parts['future']
    assert_equal 1, parts['living']
  end

  def test_split_caps_living_at_the_monthly_target
    @user.update(living_target: cedis(1000))
    ledger(@user).income(amount: cedis(1500), account: @momo, on: Date.today)
    split = plan(@user).split(cedis(1000))
    parts = split[:parts].transform_keys(&:kind)
    assert_equal cedis(250), parts['living']
    assert_equal cedis(250), split[:overflow]
    assert_equal cedis(200) + cedis(250), parts['future']
    assert_equal cedis(1000), parts.values.sum
  end

  def test_next_income_on
    assert_equal Date.new(2026, 11, 1), plan(@user, Date.new(2026, 10, 20)).next_income_on
    @user.update(payday: 25)
    assert_equal Date.new(2026, 10, 25), plan(@user, Date.new(2026, 10, 20)).next_income_on
    assert_equal Date.new(2026, 11, 25), plan(@user, Date.new(2026, 10, 25)).next_income_on
    @user.update(payday: 31)
    assert_equal Date.new(2027, 2, 28), plan(@user, Date.new(2027, 2, 10)).next_income_on
    assert_equal Date.new(2027, 3, 31), plan(@user, Date.new(2027, 2, 28)).next_income_on
  end

  def test_safe_to_spend_spreads_enjoy_to_the_next_income
    day = Date.new(2026, 10, 20)
    ledger(@user, day).income(amount: cedis(3000), account: @momo, on: day) # Enjoy 600
    ledger(@user, day).spend(amount: cedis(50), pot: @user.pot('enjoy'), account: @momo, on: day)
    safe = plan(@user, day).safe_to_spend # 12 days to 1 Nov
    assert_equal 12, safe[:days]
    assert_equal cedis(50), safe[:allowance]
    assert_equal cedis(50), safe[:spent]
    assert_equal 0, safe[:left]

    @user.update(payday: 25)
    safe = plan(@user, day).safe_to_spend # 5 days to the 25th
    assert_equal cedis(120), safe[:allowance]
    assert_equal cedis(70), safe[:left]
  end

  def test_suggests_moving_money_to_its_home_account
    ledger(@user).income(amount: cedis(1000), account: @momo, on: Date.today)
    moves = plan(@user).suggested_moves
    assert_equal 1, moves.size
    assert_equal [@momo.id, @bank.id], [moves.first[:from].id, moves.first[:to].id]
    assert_equal({ 'future' => cedis(200), 'buy' => cedis(100) }, moves.first[:parts].transform_keys(&:kind))

    ledger(@user).move(parts: moves.first[:parts], from: @momo, to: @bank, on: Date.today)
    assert_empty plan(@user).suggested_moves
  end

  def test_suggests_covering_a_pot_spent_from_the_wrong_account
    ledger(@user).income(amount: cedis(1000), pot: @user.pot('enjoy'), account: @momo, on: Date.today)
    ledger(@user).spend(amount: cedis(50), pot: @user.pot('enjoy'), account: @bank, on: Date.today)
    moves = plan(@user).suggested_moves
    assert_equal [[@momo.id, @bank.id, { 'enjoy' => cedis(50) }]],
                 moves.map { |m| [m[:from].id, m[:to].id, m[:parts].transform_keys(&:kind)] }
  end

  def test_buy_list_fills_items_top_first
    ledger(@user).income(amount: cedis(300), pot: @user.pot('buy'), account: @bank, on: Date.today)
    first = BuyItem.create(user_id: @user.id, name: 'Phone', price: cedis(200), status: 'listed')
    second = BuyItem.create(user_id: @user.id, name: 'Laptop', price: cedis(500), status: 'listed')
    BuyItem.create(user_id: @user.id, name: 'Shoes', price: cedis(100), status: 'cooling', cooling_until: Time.now + 3600)
    list = plan(@user).buy_list
    assert_equal [[first.id, cedis(200)], [second.id, cedis(100)]], list[:items].map { |r| [r[:item].id, r[:filled]] }
    assert_equal cedis(400), list[:items].last[:needed]
    assert_equal 0, list[:spare]
  end

  def test_emergency_fund_counts_cash_savings_and_quick_holdings
    @user.update(living_target: cedis(1000), emergency_months: 3)
    ledger(@user).opening([[@user.pot('future'), @bank, cedis(2700)]], on: Date.today)
    fund = Investment.create(user_id: @user.id, kind: 'fund', name: 'MMF', principal: cedis(500), value: cedis(500),
                             started_on: Date.today, emergency: true, status: 'active')
    ledger(@user).open_investment(fund, from: @bank, on: Date.today)
    tbill = Investment.create(user_id: @user.id, kind: 'tbill', name: 'T-bill', principal: cedis(1000), value: cedis(1000),
                              started_on: Date.today, emergency: false, status: 'active')
    ledger(@user).open_investment(tbill, from: @bank, on: Date.today)

    emergency = plan(@user).emergency
    assert_equal cedis(3000), emergency[:target]
    assert_equal cedis(1200) + cedis(500), emergency[:saved]
    refute emergency[:done]
  end

  def test_unbanked_cash_nudge
    cash = account(@user, 'Cash')
    ledger(@user).income(amount: cedis(100), pot: @user.pot('living'), account: cash, on: Date.today - 8)
    assert_equal [cash.id], plan(@user).unbanked_cash.map { |row| row[:account].id }
    ledger(@user).move(parts: { @user.pot('living') => cedis(100) }, from: cash, to: @momo, on: Date.today)
    assert_empty plan(@user).unbanked_cash
  end
end
