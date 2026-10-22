require 'date'

# Read-side figures for one user: balances, how an income splits, what is safe
# to spend today, suggested moves, Buy List progress, the emergency fund and
# the monthly review. Amounts are pesewas.
class Plan
  # Smaller leftovers aren't worth a transfer.
  MIN_MOVE = 100

  attr_reader :user, :today

  def initialize(user, today: Date.today)
    @user = user
    @today = today
  end

  def entries
    Entry.where(user_id: user.id)
  end

  # {[pot_id, account_id] => pesewas}
  def balances
    @balances ||= entries.select_group(:pot_id, :account_id).select_append { sum(:amount).as(:total) }
                         .to_h { |row| [[row[:pot_id], row[:account_id]], row[:total].to_i] }
  end

  def pot_balance(pot)
    balances.sum { |(pot_id, _), total| pot_id == pot.id ? total : 0 }
  end

  def account_balance(account)
    balances.sum { |(_, account_id), total| account_id == account.id ? total : 0 }
  end

  def balance_at(pot, account)
    balances.fetch([pot.id, account.id], 0)
  end

  def total
    balances.values.sum
  end

  # What the saved starting balances put in each pot and account:
  # {[account_id, pot_id] => pesewas}.
  def starting_balances
    openings = Transaction.where(user_id: user.id, kind: 'opening').select(:id)
    entries.where(transaction_id: openings).select_group(:account_id, :pot_id).select_append { sum(:amount).as(:total) }
           .to_h { |row| [[row[:account_id], row[:pot_id]], row[:total].to_i] }
  end

  # How an income is shared between the pots. Pesewas lost to rounding go to
  # Future Me, and so does Living's share once this month's living target is met.
  def split(amount, on = today)
    future = user.pot('future')
    living = user.pot('living')
    parts = user.pots.to_h { |pot| [pot, amount * pot.percent / 100] }
    parts[future] += amount - parts.values.sum
    room = living_room(on)
    overflow = room && parts[living] > room ? parts[living] - room : 0
    parts[living] -= overflow
    parts[future] += overflow
    { parts: parts, overflow: overflow, room: room }
  end

  # How much more Living may take from income this month before the target is
  # met; nil when no target is set.
  def living_room(on = today)
    return nil unless user.living_target

    received = entries.where(pot_id: user.pot('living').id, flow: 'income', occurred_on: month_range(on)).sum(:amount).to_i
    [user.living_target - received, 0].max
  end

  # The day the next income is expected: the payday, or the first of next
  # month when income is irregular.
  def next_income_on
    day = user.payday
    return Date.new(today.year, today.month, -1) + 1 unless day

    this_month = day_in_month(today, day)
    this_month > today ? this_month : day_in_month(today >> 1, day)
  end

  # Today's share of the Enjoy pot: what it held this morning spread over the
  # days to the next income, less what has been spent from it today.
  def safe_to_spend
    enjoy = user.pot('enjoy')
    days = [(next_income_on - today).to_i, 1].max
    spent = -entries.where(pot_id: enjoy.id, flow: Entry::SPENDING, occurred_on: today).sum(:amount).to_i
    balance = pot_balance(enjoy)
    start = balance + spent
    allowance = start.positive? ? start / days : 0
    { allowance: allowance, spent: spent, left: allowance - spent, days: days, balance: balance, next_income_on: next_income_on }
  end

  # Bills Living has to keep their whole amount back for now: this month's
  # that aren't paid yet (overdue ones included), and those falling due by the
  # next income. Each: {bill:, month:, due_on:, overdue:}.
  def bills_due
    @bills_due ||= begin
      this_month = Date.new(today.year, today.month, 1)
      active_bills.flat_map do |bill|
        if bill.monthly?
          [this_month, this_month >> 1].filter_map do |month|
            due = bill.due_on(month)
            next if bill_paid?(bill, month)
            next if bill.starts_on && month < bill.starts_on
            next if month != this_month && due >= next_income_on

            { bill: bill, month: month, due_on: due, overdue: due < today }
          end
        else
          due = bill_date(bill)
          next [] unless due && (due < this_month >> 1 || due <= next_income_on)

          [{ bill: bill, month: month_start(due), due_on: due, overdue: due < today }]
        end
      end
    end
  end

  # Bills that aren't monthly and aren't due yet. Living sets their money
  # aside a share at a time, on each income between the last pay-by date (or
  # the day the bill was added) and the next, so it's all there in time.
  # Each: {bill:, due_on:, kept:, per_income:, incomes:, next_on:, next_share:}.
  def bill_savings
    @bill_savings ||= begin
      due = bills_due.map { |d| d[:bill].id }
      active_bills.filter_map do |bill|
        next if bill.monthly? || due.include?(bill.id)

        date = bill_date(bill)
        next unless date

        since = [bill.date_before(date), bill.created_at.to_date].compact.max
        steps = income_dates(since, date)
        done = steps.count { |day| day <= today }
        kept = steps.empty? ? bill.amount : bill.amount * done / steps.size
        next_on = steps[done]
        {
          bill: bill, due_on: date, kept: kept, per_income: (bill.amount.to_f / [steps.size, 1].max).ceil,
          incomes: steps.size, next_on: next_on, next_share: next_on && (bill.amount * (done + 1) / steps.size) - kept
        }
      end
    end
  end

  # The pay-by date a bill that isn't monthly is working towards: its latest
  # one while that's unpaid (overdue), else the next unpaid one. nil once a
  # one-off is paid.
  def bill_date(bill)
    bill.dates_from(today).find { |date| !bill_paid?(bill, month_start(date)) }
  end

  # The day the first thing was recorded here (today when nothing is yet).
  # Anything paid before it was paid outside the app.
  def started_on
    @started_on ||= to_date(Transaction.where(user_id: user.id).min(:occurred_on)) || today
  end

  # A bill (being added or edited) whose latest date has passed, before the
  # first record here and unpaid: it was probably paid outside the app, so
  # the form asks. {date:, next:} or nil. Not asked twice, nor for a one-off.
  def bill_passed_unrecorded(bill)
    return nil if bill.once? || bill.starts_on

    this_month = Date.new(today.year, today.month, 1)
    date = bill.monthly? ? bill.due_on(this_month) : bill_date(bill)
    return nil unless date && date < today && date < started_on && !bill_paid?(bill, month_start(date))

    following = bill.monthly? ? bill.due_on(this_month >> 1) : bill.dates_from(today).find { |day| day > today }
    { date: date, next: following }
  end

  # The month a payment for this bill counts towards. Monthly: its oldest
  # unpaid month, else the month it was paid in. Others: the month of the
  # pay-by date it's working towards.
  def bill_month_for(bill, on = today)
    date = bill.monthly? ? bills_due.find { |due| due[:bill].id == bill.id }&.dig(:month) : bill_date(bill)
    month_start(date || on)
  end

  # The payment to show for each active bill: this month's for a monthly
  # bill, the latest for others. {bill_id => Transaction}.
  def bills_paid
    this_month = Date.new(today.year, today.month, 1)
    monthly = active_bills.select(&:monthly?).map(&:id)
    Transaction.where(user_id: user.id, bill_id: active_bills.map(&:id)).order(:occurred_on, :id).all
               .select { |txn| !monthly.include?(txn.bill_id) || to_date(txn.bill_month) == this_month }
               .to_h { |txn| [txn.bill_id, txn] }
  end

  # Roughly what the bills need from Living a month: monthly ones in full, a
  # term's or a year's spread over its months, and a one-off's share of each
  # income while it's being saved for.
  def bills_monthly
    active_bills.sum do |bill|
      if bill.monthly? then bill.amount
      elsif bill.once? then bill_savings.find { |saving| saving[:bill].id == bill.id }&.dig(:per_income).to_i
      else bill.amount / Bill::MONTHS.fetch(bill.repeats)
      end
    end
  end

  # Today's share of Living for everyday costs (food, transport, data): what
  # Living holds beyond the bills due and what's set aside for bigger ones,
  # spread over the days to the next income, less what everyday costs have
  # taken today. Paying a bill doesn't count against it: the money was
  # already kept back.
  def living_today
    living = user.pot('living')
    days = [(next_income_on - today).to_i, 1].max
    saving = bill_savings.select { |s| s[:kept].positive? }
    kept = bills_due.sum { |due| due[:bill].amount } + saving.sum { |s| s[:kept] }
    bill_payments = Transaction.where(user_id: user.id).exclude(bill_id: nil).select(:id)
    spent = -entries.where(pot_id: living.id, flow: Entry::SPENDING, occurred_on: today)
                    .exclude(transaction_id: bill_payments).sum(:amount).to_i
    free = pot_balance(living) - kept
    start = free + spent
    allowance = start.positive? ? start / days : 0
    bills = (bills_due + saving).map { |item| item[:bill].id }.uniq.size
    { allowance: allowance, spent: spent, left: allowance - spent, days: days, kept: kept, free: free, bills: bills }
  end

  # The pot the last spend to this payee came from, to suggest it again.
  def pot_for_payee(payee)
    name = payee.to_s.strip.downcase
    return nil if name.empty?

    txn = Transaction.where(user_id: user.id, kind: 'spend').where(Sequel.function(:lower, :payee) => name).reverse(:id).first
    pot_id = txn && Entry.where(transaction_id: txn.id).order(:id).get(:pot_id)
    user.pots.find { |pot| pot.id == pot_id }
  end

  # Transfers that would put each pot's money where it belongs: out of the
  # wrong account into the pot's home account, and into any account where the
  # pot has gone below zero (usually money spent from an account it wasn't
  # in). Grouped by from/to so one real transfer covers several pots.
  def suggested_moves
    moves = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    accounts = user.cash_accounts
    user.pots.each do |pot|
      home = pot.home_account_id && accounts.find { |a| a.id == pot.home_account_id }
      accounts.each do |account|
        held = balance_at(pot, account)
        if home && account != home && held >= MIN_MOVE
          moves[[account, home]][pot] += held
        elsif held <= -MIN_MOVE
          source = cover_source(pot, account, home, accounts)
          amount = source ? [-held, balance_at(pot, source)].min : 0
          moves[[source, account]][pot] += amount if amount >= MIN_MOVE
        end
      end
    end
    moves.map { |(from, to), parts| { from: from, to: to, parts: parts, total: parts.values.sum } }
  end

  # Cash income left unbanked for a week or more. Banking cash weekly stops it
  # disappearing unnoticed.
  def unbanked_cash
    user.cash_accounts.select(&:cash?).filter_map do |account|
      balance = account_balance(account)
      next if balance < MIN_MOVE

      last_out = to_date(entries.where(account_id: account.id, flow: 'move').where { amount < 0 }.max(:occurred_on))
      incomes = entries.where(account_id: account.id, flow: 'income')
      incomes = incomes.where { occurred_on > last_out } if last_out
      since = to_date(incomes.min(:occurred_on))
      next if since.nil? || (today - since).to_i < 7

      { account: account, balance: balance, days: (today - since).to_i }
    end
  end

  # Wants whose cooling-off time is over, waiting for a decision.
  def cooled_items
    BuyItem.where(user_id: user.id, status: 'cooling').where(Sequel[:cooling_until] <= Time.now).order(:cooling_until).all
  end

  def maturities(within: 14)
    Investment.where(user_id: user.id, status: 'active').exclude(matures_on: nil)
              .where(Sequel[:matures_on] <= today + within).order(:matures_on).all
  end

  # Buy List money fills the listed items top first. For each item: what it
  # has, what is still short (counting the items above it), when it should be
  # ready at the pot's recent rate, and the weekly amount its target date needs.
  def buy_list
    available = [pot_balance(user.pot('buy')), 0].max
    rate = buy_monthly_rate
    needed = 0
    items = BuyItem.where(user_id: user.id).listed.all.map do |item|
      filled = [item.price, available].min
      available -= filled
      needed += item.price - filled
      weeks = item.target_on && item.target_on > today ? ((item.target_on - today).to_i / 7.0).ceil : nil
      {
        item: item, filled: filled, short: item.price - filled, needed: needed,
        ready_on: rate&.positive? && needed.positive? ? today + (needed * 30.0 / rate).ceil : nil,
        per_week: weeks && needed.positive? ? (needed.to_f / weeks).ceil : nil,
        late: item.target_on && item.target_on < today && needed.positive?
      }
    end
    { items: items, spare: available, rate: rate }
  end

  def buy_monthly_rate
    income_rate(user.pot('buy'))
  end

  # What a pot received from income per 30 days over the last 90 (or since
  # the first entry); nil until there are two weeks of history.
  def income_rate(pot)
    first = to_date(entries.min(:occurred_on))
    return nil unless first

    from = [first, today - 89].max
    days = (today - from).to_i + 1
    return nil if days < 14

    received = entries.where(pot_id: pot.id, flow: 'income', occurred_on: from..today).sum(:amount).to_i
    received * 30 / days
  end

  # A month of living costs: the target from settings, or the average Living
  # spending over the last (up to) three full months.
  def monthly_living
    return { amount: user.living_target, source: :target } if user.living_target

    first = to_date(entries.min(:occurred_on))
    return nil unless first

    this_month = Date.new(today.year, today.month, 1)
    counted_from = first.day == 1 ? first : Date.new(first.year, first.month, 1) >> 1
    months = [((this_month.year * 12) + this_month.month) - ((counted_from.year * 12) + counted_from.month), 3].min
    return nil unless months.positive?

    spent = -entries.where(pot_id: user.pot('living').id, flow: Entry::SPENDING, occurred_on: (this_month << months)...this_month).sum(:amount).to_i
    spent.positive? ? { amount: spent / months, source: :average, months: months } : nil
  end

  # Future Me money that can be reached within days: what isn't invested, plus
  # holdings marked as counting towards the emergency fund.
  def emergency
    future = user.pot('future')
    invested = balance_at(future, user.investments_account)
    reserved = Investment.where(user_id: user.id, status: 'active', emergency: true).sum(:value).to_i
    saved = pot_balance(future) - invested + reserved
    living = monthly_living
    target = living && living[:amount] * user.emergency_months
    {
      saved: saved, target: target, living: living, invested: invested,
      months: living ? saved.to_f / living[:amount] : nil,
      done: target ? saved >= target : false
    }
  end

  # Pots that have gone below zero overall.
  def overdrawn
    user.pots.filter_map { |pot| (balance = pot_balance(pot)).negative? ? [pot, balance] : nil }
  end

  def review(month)
    range = month_range(month)
    month_entries = entries.where(occurred_on: range)
    incomes = Transaction.where(user_id: user.id, kind: 'income', occurred_on: range)
    by_pot = ->(dataset) { dataset.select_group(:pot_id).select_append { sum(:amount).as(:total) }.to_h { |r| [r[:pot_id], r[:total].to_i] } }
    income = incomes.sum(:amount).to_i
    into = by_pot.call(month_entries.where(flow: 'income'))
    {
      range: range,
      income: income,
      sources: incomes.select_group(:source).select_append { sum(:amount).as(:total) }.order(Sequel.desc(:total)).all
                      .map { |r| [r[:source].to_s.empty? ? 'Other' : r[:source], r[:total].to_i] },
      into: into,
      spent: by_pot.call(month_entries.where(flow: Entry::SPENDING)).transform_values(&:-@),
      saving_rate: income.positive? ? (into.fetch(user.pot('future').id, 0) * 100.0 / income).round : nil,
      growth: month_entries.where(flow: 'growth').sum(:amount).to_i,
      worth_start: entries.where(Sequel[:occurred_on] < range.first).sum(:amount).to_i,
      worth_end: entries.where(Sequel[:occurred_on] <= range.last).sum(:amount).to_i,
      bought: BuyItem.where(user_id: user.id, status: 'bought', bought_on: range).order(:bought_on).all,
      biggest: Transaction.where(user_id: user.id, kind: 'spend', occurred_on: range).order(Sequel.desc(:amount)).limit(5).all
    }
  end

  def month_range(date)
    Date.new(date.year, date.month, 1)..Date.new(date.year, date.month, -1)
  end

  private

  def active_bills
    @active_bills ||= Bill.where(user_id: user.id).active.all
  end

  def bill_paid?(bill, month)
    @paid_months ||= Transaction.where(user_id: user.id).exclude(bill_id: nil).select_map([:bill_id, :bill_month])
                                .to_set { |id, paid_month| [id, to_date(paid_month)] }
    @paid_months.include?([bill.id, month])
  end

  # The days income is expected after from and before to: each payday, or the
  # first of each month when income is irregular.
  def income_dates(from, to)
    dates = []
    month = Date.new(from.year, from.month, 1)
    while month < to
      day = user.payday ? day_in_month(month, user.payday) : month
      dates << day if day > from && day < to
      month >>= 1
    end
    dates
  end

  def month_start(date)
    Date.new(date.year, date.month, 1)
  end

  # Where to take a pot's money from to cover it in an account where it went
  # below zero: its home account, else wherever it holds the most.
  def cover_source(pot, account, home, accounts)
    return home if home && home != account && balance_at(pot, home).positive?

    accounts.reject { |a| a == account }.max_by { |a| balance_at(pot, a) }
            .then { |best| best && balance_at(pot, best).positive? ? best : nil }
  end

  def day_in_month(date, day)
    Date.new(date.year, date.month, [day, Date.new(date.year, date.month, -1).day].min)
  end

  # SQLite hands aggregate dates back as strings.
  def to_date(value)
    value.is_a?(String) ? Date.parse(value) : value
  end
end
