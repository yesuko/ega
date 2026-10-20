require 'json'

# Writes money events: one transactions row and its signed entries, inside one
# database transaction. The routes check the inputs; amounts are pesewas.
# Investments always belong to the Future Me pot.
class Ledger
  attr_reader :user, :plan

  def initialize(user, plan = Plan.new(user))
    @user = user
    @plan = plan
  end

  # Shares the income between the pots, or puts it all in one pot (a refund,
  # money returned) when pot is given.
  def income(amount:, account:, on:, source: nil, note: nil, pot: nil, external_ref: nil)
    parts = pot ? { pot => amount } : plan.split(amount, on)[:parts]
    record('income', amount: amount, on: on, source: source, note: note, external_ref: external_ref) do |lines|
      parts.each { |part_pot, value| lines << [part_pot, account, value, 'income'] }
    end
  end

  def spend(amount:, pot:, account:, on:, note: nil, external_ref: nil)
    record('spend', amount: amount, on: on, note: note, external_ref: external_ref) do |lines|
      lines << [pot, account, -amount, 'spend']
    end
  end

  # parts: {pot => pesewas} moved from one account to another. A transfer fee
  # is spent from fee_pot at the sending account.
  def move(parts:, from:, to:, on:, note: nil, fee: 0, fee_pot: nil)
    record('move', amount: parts.values.sum, fee: fee, on: on, note: note) do |lines|
      parts.each do |pot, value|
        lines << [pot, from, -value, 'move']
        lines << [pot, to, value, 'move']
      end
      lines << [fee_pot, from, -fee, 'fee'] if fee.positive?
    end
  end

  # Gives money from one pot to another without it changing account.
  def shift(amount:, from_pot:, to_pot:, account:, on:, note: nil)
    record('shift', amount: amount, on: on, note: note) do |lines|
      lines << [from_pot, account, -amount, 'shift']
      lines << [to_pot, account, amount, 'shift']
    end
  end

  # Brings an account in line with its real balance. A shortfall is spending
  # that wasn't recorded; a surplus is added to a pot, or split as income.
  # Returns nil when the account already matches.
  def check(account:, actual:, pot:, on:, as_income: false)
    difference = actual - plan.account_balance(account)
    return nil if difference.zero?

    note = "Balance check: #{account.name}"
    return income(amount: difference, account: account, on: on, source: 'Unrecorded', note: note) if difference.positive? && as_income

    record('check', amount: difference.abs, on: on, note: note) do |lines|
      lines << [pot, account, difference, difference.negative? ? 'spend' : 'check']
    end
  end

  # rows: [[pot, account, pesewas], ...] for money held before using the app.
  def opening(rows, on:)
    record('opening', amount: rows.sum { |_, _, value| value }, on: on, note: 'Starting balances') do |lines|
      rows.each { |pot, account, value| lines << [pot, account, value, 'opening'] }
    end
  end

  # Pays for a Buy List item from the Buy List pot. Whatever the pot can't
  # cover comes from cover_pot.
  def buy(item:, paid:, account:, on:, cover_pot: nil)
    buy_pot = user.pot('buy')
    from_list = cover_pot ? paid.clamp(0, [plan.pot_balance(buy_pot), 0].max) : paid
    DB.transaction do
      txn = record('spend', amount: paid, on: on, note: "Bought: #{item.name}", buy_item_id: item.id, snapshot: item.snapshot.to_json) do |lines|
        lines << [buy_pot, account, -from_list, 'spend']
        lines << [cover_pot, account, -(paid - from_list), 'spend'] if cover_pot
      end
      item.update(status: 'bought', bought_on: on, paid: paid)
      txn
    end
  end

  # Records a new holding (already saved) and the money put into it. from: the
  # account it was paid from, or nil for an investment held before the app.
  def open_investment(investment, from:, on:)
    record_investment('invest', investment, amount: investment.principal, on: on, note: 'Opened', snapshot: nil) do |lines|
      invest_lines(lines, investment.principal, from)
    end
  end

  def top_up(investment, amount:, from:, on:)
    record_investment('invest', investment, amount: amount, on: on, note: 'Added money') do |lines|
      invest_lines(lines, amount, from)
      investment.update(principal: investment.principal + amount, value: investment.value + amount)
    end
  end

  # Records what a holding is worth now; the difference is growth (or a loss).
  def revalue(investment, value:, on:)
    change = value - investment.value
    return nil if change.zero?

    record_investment('growth', investment, amount: change.abs, on: on, note: change.positive? ? 'Value went up' : 'Value went down') do |lines|
      lines << [future, holding, change, 'growth']
      investment.update(value: value)
    end
  end

  # Takes money out into an account. Closing takes everything: any difference
  # from the recorded value is growth. A partial withdrawal reduces what was
  # put in by the same share.
  def cash_out(investment, amount:, to:, on:, close:)
    record_investment('cashout', investment, amount: amount, on: on, note: close ? 'Closed' : 'Took money out') do |lines|
      growth = close ? amount - investment.value : 0
      lines << [future, holding, growth, 'growth']
      lines << [future, holding, -amount, 'cashout']
      lines << [future, to, amount, 'cashout']
      if close
        investment.update(status: 'closed', closed_on: on, value: amount)
      else
        investment.update(value: investment.value - amount,
                          principal: investment.principal - (investment.principal * amount / investment.value))
      end
    end
  end

  # Removes an event and puts back the Buy List item or investment it changed.
  # An investment's first event removes the investment with it.
  def delete(txn)
    DB.transaction do
      data = txn.snapshot_data
      investment = txn.investment
      item = txn.buy_item
      Entry.where(transaction_id: txn.id).delete
      txn.delete
      if investment
        data ? investment.restore(data) : investment.destroy
      elsif item && data
        item.restore(data)
      end
    end
  end

  private

  def future
    user.pot('future')
  end

  def holding
    user.investments_account
  end

  def invest_lines(lines, amount, from)
    if from
      lines << [future, from, -amount, 'invest']
      lines << [future, holding, amount, 'invest']
    else
      lines << [future, holding, amount, 'opening']
    end
  end

  def record_investment(kind, investment, amount:, on:, note:, snapshot: investment.snapshot.to_json, &block)
    record(kind, amount: amount, on: on, note: note, investment_id: investment.id, snapshot: snapshot, &block)
  end

  # Creates the transaction, then one entry per [pot, account, pesewas, flow]
  # line the block adds. Zero lines are skipped.
  def record(kind, amount:, on:, **attributes)
    DB.transaction do
      txn = Transaction.create(user_id: user.id, kind: kind, amount: amount, occurred_on: on, created_at: Time.now, **attributes)
      lines = []
      yield lines
      lines.each do |pot, account, value, flow|
        next if value.zero?

        Entry.create(transaction_id: txn.id, user_id: user.id, pot_id: pot.id, account_id: account.id,
                     amount: value, flow: flow, occurred_on: on)
      end
      txn
    end
  end
end
