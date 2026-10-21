require 'test_helper'

class LedgerTest < Minitest::Test
  def setup
    @user = make_user
    @momo = account(@user, 'MoMo')
    @bank = account(@user, 'Bank savings')
    @holding = account(@user, 'Investments')
  end

  def balance(pot_kind, account = nil)
    p = plan(@user)
    account ? p.balance_at(@user.pot(pot_kind), account) : p.pot_balance(@user.pot(pot_kind))
  end

  def test_income_entries_add_up_to_the_amount
    txn = ledger(@user).income(amount: cedis(1234.57), account: @momo, on: Date.today, source: 'Salary')
    assert_equal cedis(1234.57), txn.entries.sum(&:amount)
    assert_equal cedis(1234.57), plan(@user).account_balance(@momo)
  end

  def test_income_to_one_pot
    ledger(@user).income(amount: cedis(80), account: @momo, on: Date.today, pot: @user.pot('enjoy'))
    assert_equal cedis(80), balance('enjoy')
    assert_equal 0, balance('future')
  end

  def test_move_keeps_pots_and_charges_the_fee
    ledger(@user).income(amount: cedis(1000), account: @momo, on: Date.today)
    ledger(@user).move(parts: { @user.pot('future') => cedis(200) }, from: @momo, to: @bank, on: Date.today,
                       fee: cedis(1.5), fee_pot: @user.pot('living'))
    assert_equal cedis(200), balance('future', @bank)
    assert_equal 0, balance('future', @momo)
    assert_equal cedis(498.5), balance('living', @momo)
    assert_equal cedis(998.5), plan(@user).total
  end

  def test_check_records_a_shortfall_as_spending
    ledger(@user).income(amount: cedis(1000), account: @momo, on: Date.today)
    txn = ledger(@user).check(account: @momo, actual: cedis(940), pot: @user.pot('living'), on: Date.today)
    assert_equal 'spend', txn.entries.first.flow
    assert_equal cedis(940), plan(@user).account_balance(@momo)
    assert_equal cedis(440), balance('living')
  end

  def test_check_can_split_a_surplus_as_income
    txn = ledger(@user).check(account: @momo, actual: cedis(100), pot: @user.pot('living'), on: Date.today, as_income: true)
    assert_equal 'income', txn.kind
    assert_equal cedis(20), balance('future')
    assert_nil ledger(@user).check(account: @momo, actual: cedis(100), pot: @user.pot('living'), on: Date.today)
  end

  def test_buying_covers_the_rest_from_another_pot_and_deleting_puts_it_back
    ledger(@user).income(amount: cedis(2000), account: @bank, on: Date.today) # Buy List 200, Enjoy 400
    item = BuyItem.create(user_id: @user.id, name: 'Headphones', price: cedis(250), status: 'listed')
    txn = ledger(@user).buy(item: item, paid: cedis(250), account: @bank, on: Date.today, cover_pot: @user.pot('enjoy'))
    assert_equal 0, balance('buy')
    assert_equal cedis(350), balance('enjoy')
    assert_equal 'bought', item.refresh.status

    ledger(@user).delete(txn)
    assert_equal 'listed', item.refresh.status
    assert_equal cedis(200), balance('buy')
    assert_equal cedis(400), balance('enjoy')
  end

  def test_investment_lifecycle_and_undo
    ledger(@user).opening([[@user.pot('future'), @bank, cedis(2000)]], on: Date.today)
    fund = Investment.create(user_id: @user.id, kind: 'fund', name: 'MMF', principal: cedis(1000), value: cedis(1000),
                             started_on: Date.today, status: 'active')
    ledger(@user).open_investment(fund, from: @bank, on: Date.today)
    assert_equal cedis(1000), balance('future', @bank)
    assert_equal cedis(1000), balance('future', @holding)

    ledger(@user).top_up(fund.refresh, amount: cedis(100), from: @bank, on: Date.today)
    ledger(@user).revalue(fund.refresh, value: cedis(1150), on: Date.today)
    assert_equal [cedis(1100), cedis(1150)], [fund.refresh.principal, fund.value]
    assert_equal cedis(1150), balance('future', @holding)

    ledger(@user).cash_out(fund.refresh, amount: cedis(230), to: @bank, on: Date.today, close: false)
    assert_equal [cedis(880), cedis(920)], [fund.refresh.principal, fund.value] # put-in shrinks by the same 20%

    ledger(@user).cash_out(fund.refresh, amount: cedis(950), to: @bank, on: Date.today, close: true)
    fund.refresh
    assert_equal ['closed', cedis(950)], [fund.status, fund.value]
    assert_equal 0, balance('future', @holding)
    assert_equal cedis(2080), balance('future', @bank) # 2,000 + 50 growth + 30 more at closing

    # Undo newest first, all the way back.
    5.times do
      latest = Transaction.where(investment_id: fund.id).order(Sequel.desc(:id)).first
      ledger(@user).delete(latest)
    end
    assert_nil Investment[fund.id]
    assert_equal cedis(2000), balance('future', @bank)
    assert_equal 0, balance('future', @holding)
  end

  def test_undoing_a_close_reopens_the_investment
    tbill = Investment.create(user_id: @user.id, kind: 'tbill', name: 'T-bill', principal: cedis(1000), value: cedis(1000),
                              started_on: Date.today - 91, matures_on: Date.today, rate: BigDecimal('18.2'), status: 'active')
    ledger(@user).open_investment(tbill, from: nil, on: tbill.started_on) # held before the app
    assert_equal cedis(1045.50), tbill.expected_at_maturity
    txn = ledger(@user).cash_out(tbill.refresh, amount: cedis(1045.50), to: @bank, on: Date.today, close: true)
    assert_equal cedis(1045.50), balance('future', @bank)
    ledger(@user).delete(txn)
    tbill.refresh
    assert_equal ['active', cedis(1000), nil], [tbill.status, tbill.value, tbill.closed_on]
    assert_equal cedis(1000), balance('future', @holding)
  end

  def test_deleting_an_event_reverses_it
    txn = ledger(@user).income(amount: cedis(500), account: @momo, on: Date.today)
    ledger(@user).delete(txn)
    assert_equal 0, plan(@user).total
    assert_equal 0, Entry.where(user_id: @user.id).count
  end
end
