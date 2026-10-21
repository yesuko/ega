require 'dotenv'
require 'sinatra'
require 'sequel'
require 'json'
require 'date'
require 'time'
require 'uri'
require 'securerandom'
require 'fileutils'
require 'logger'

Dotenv.overload(File.expand_path('.env', __dir__)) unless ENV['RACK_ENV'] == 'test'
# Ghana time (GMT, no daylight saving) decides what "today" is.
ENV['TZ'] = ENV.fetch('APP_TIMEZONE', 'Africa/Accra')

set :host_authorization, {}
set :port, ENV.fetch('PORT', 4600)
# Escape <%= %> output by default; trusted markup must opt in with <%== %>.
set :erb, escape_html: true
# Stay logged in on your phone for 30 days. In production (behind HTTPS) the
# cookie is only ever sent over HTTPS.
set :sessions, key: 'ega.session', secret: ENV.fetch('SESSION_SECRET'), expire_after: 30 * 24 * 3600,
               same_site: :lax, secure: production?
set :session_secret, ENV.fetch('SESSION_SECRET')

LOG_FILE = File.expand_path('log/application.log', __dir__)
FileUtils.mkdir_p(File.dirname(LOG_FILE))
APP_LOGGER = ENV['RACK_ENV'] == 'test' ? Logger.new(File::NULL) : Logger.new(LOG_FILE, 'daily')

DB = Sequel.connect(ENV.fetch('DATABASE_URL')) unless defined?(DB)
# Passenger can run several app processes against the one SQLite file: WAL lets
# reads carry on during a write, and Sequel's sqlite adapter waits up to 5s for
# a lock instead of failing.
DB.run('PRAGMA journal_mode = WAL') if DB.database_type == :sqlite

require_relative 'lib/money'
require_relative 'lib/icons'
require_relative 'lib/sms_parser'
require_relative 'models/user'
require_relative 'models/account'
require_relative 'models/pot'
require_relative 'models/buy_item'
require_relative 'models/investment'
require_relative 'models/transaction'
require_relative 'models/entry'
require_relative 'models/inbox_message'
require_relative 'lib/plan'
require_relative 'lib/ledger'

INCOME_SOURCES = ['Salary', 'Client work', 'Side job', 'Gift', 'Refund'].freeze
# Sign-up is open to anyone; this stops one address creating accounts in bulk.
SIGNUPS_PER_IP_PER_DAY = 5
# A phone forwarding every SMS by mistake can't fill an inbox past this.
INBOX_MESSAGES_PER_DAY = 300

before do
  # The SMS inbox token is a secret, so it stays out of the log.
  APP_LOGGER.info("Request: #{request.request_method} #{request.path.sub(%r{\A/sms/[^/]+}, '/sms/[token]')}")
end

# Routes have no trailing slash, so send /buy/ (and the like) to /buy.
before %r{.+/} do
  redirect request.fullpath.sub(%r{/+(?=\?|\z)}, '')
end

before do
  public_path = %w[/login /signup].include?(request.path_info) || request.path_info.match?(%r{\A/sms/[^/]+\z})
  redirect '/login' unless current_user || public_path
end

helpers do
  def current_user
    @current_user ||= session[:user_id] && User[session[:user_id]]
  end

  def plan
    @plan ||= Plan.new(current_user)
  end

  def ledger
    Ledger.new(current_user, plan)
  end

  def icon(name, size: 20, css_class: nil)
    Icons.svg(name, size: size, css_class: css_class)
  end

  def cedis(pesewas, short: false)
    "GH₵ #{Money.format(pesewas, short: short)}"
  end

  # "+GH₵ 50.00" / "−GH₵ 20.00" for amounts that add or take away.
  def signed(pesewas, short: false)
    "#{pesewas.negative? ? '−' : '+'}#{cedis(pesewas.abs, short: short)}"
  end

  def percent_of(part, whole)
    whole.to_i.positive? ? (part * 100.0 / whole).round.clamp(0, 100) : 0
  end

  # For embedding data in <script type="application/json">: escaping <, > and &
  # stops user-supplied values from closing the script tag.
  def json_for_script(obj)
    JSON.generate(obj).gsub('<', '<').gsub('>', '>').gsub('&', '&')
  end

  # Appends the file's mtime so browsers fetch a fresh copy after each deploy.
  def asset_path(path)
    file = File.join(settings.public_folder, path)
    File.exist?(file) ? "#{path}?v=#{File.mtime(file).to_i}" : path
  end

  def notice(kind, message)
    session[:flash] = { 'kind' => kind, 'message' => message }
  end

  def take_flash
    session.delete(:flash)
  end

  def today
    Date.today
  end

  def short_date(date)
    return '' unless date

    date.year == today.year ? date.strftime('%-d %b') : date.strftime('%-d %b %Y')
  end

  def long_date(date)
    date&.strftime('%A, %-d %B %Y')
  end

  def day_label(date)
    case (today - date).to_i
    when 0 then 'Today'
    when 1 then 'Yesterday'
    else date.strftime(date.year == today.year ? '%A, %-d %B' : '%-d %B %Y')
    end
  end

  # "in 3 days", "tomorrow", "today", "2 days ago"
  def days_from_now(date)
    days = (date - today).to_i
    case days
    when 0 then 'today'
    when 1 then 'tomorrow'
    when -1 then 'yesterday'
    else days.positive? ? "in #{days} days" : "#{-days} days ago"
    end
  end

  def parse_date(raw)
    Date.iso8601(raw.to_s)
  rescue Date::Error
    nil
  end

  # "2026-10" -> 1 Oct 2026; anything else -> nil.
  def parse_month(raw)
    raw.to_s.match?(/\A\d{4}-\d{2}\z/) ? Date.new(*raw.split('-').map(&:to_i), 1) : nil
  rescue Date::Error
    nil
  end

  def date_error(date)
    if date.nil? then 'Choose a date.'
    elsif date > today then "The date can't be in the future."
    end
  end

  # A model's first validation error as a sentence: "Matures on must be after the start date".
  def first_error(model)
    attribute, messages = model.errors.first
    attribute && "#{attribute.to_s.tr('_', ' ').capitalize} #{messages.first}"
  end

  def blank_to_nil(value)
    value = value.to_s.strip
    value.empty? ? nil : value
  end

  def find_pot(id)
    current_user.pots.find { |pot| pot.id == id.to_i }
  end

  # An account money can move through (not archived, not Investments).
  def find_account(id)
    current_user.cash_accounts.find { |account| account.id == id.to_i }
  end

  # The account last used for this flow, else MoMo, else the first account.
  def default_account_id(flow)
    accounts = current_user.cash_accounts
    last = Entry.where(user_id: current_user.id, flow: flow).order(Sequel.desc(:id)).get(:account_id)
    (accounts.find { |a| a.id == last } || accounts.find { |a| a.kind == 'momo' } || accounts.first)&.id
  end

  # {account_id => {pot_id => pesewas}} for form hints.
  def balances_by_account
    current_user.cash_accounts.to_h do |account|
      [account.id, current_user.pots.to_h { |pot| [pot.id, plan.balance_at(pot, account)] }]
    end
  end

  def pot_class(pot)
    "c-#{pot.kind}"
  end

  # The heading and short description of a transaction in lists.
  def txn_title(txn)
    case txn.kind
    when 'income' then txn.source || 'Income'
    when 'spend', 'check' then txn.note || txn.kind_label
    when 'move'
      from, to = txn.entries.select { |e| e.flow == 'move' }.partition(&:negative?).map { |side| side.first&.account&.name }
      "#{from} → #{to}"
    when 'shift'
      from, to = txn.entries.partition(&:negative?).map { |side| side.first&.pot&.name }
      "#{from} → #{to}"
    when 'invest', 'growth', 'cashout' then txn.investment&.name || txn.kind_label
    else txn.kind_label
    end
  end

  def txn_detail(txn)
    pots = txn.entries.map { |e| e.pot.name }.uniq
    accounts = txn.entries.map { |e| e.account.name }.uniq
    case txn.kind
    when 'income' then [accounts.first, txn.note].compact.join(' · ')
    when 'spend' then "#{pots.join(' + ')} · #{accounts.join(', ')}"
    when 'move' then [pots.join(' + '), txn.note].compact.join(' · ')
    when 'shift' then [accounts.first, txn.note].compact.join(' · ')
    when 'check' then pots.join(', ')
    when 'invest', 'growth', 'cashout' then [txn.kind_label, txn.note].compact.join(' · ')
    else accounts.join(', ')
    end
  end

  # What a transaction did to what you own, for the amount column: income and
  # spending are signed; moves only show their size.
  def txn_amount(txn)
    case txn.kind
    when 'income', 'spend', 'check', 'growth' then [signed(txn.net), txn.net.negative? ? 'neg' : 'pos']
    else [cedis(txn.amount), '']
    end
  end

  def deletable?(txn)
    !txn.investment_event? || Transaction.where(investment_id: txn.investment_id).max(:id) == txn.id
  end
end

# --- Log in -------------------------------------------------------------------

get '/login' do
  redirect '/' if current_user
  @title = 'Log in'
  erb :login, locals: { error: nil, email: '' }
end

post '/login' do
  email = params[:email].to_s.strip.downcase
  user = User.first(email: email)
  if user&.authenticate(params[:password].to_s)
    session.clear
    session[:user_id] = user.id
    redirect '/'
  end
  APP_LOGGER.warn("Failed login for #{email}")
  @title = 'Log in'
  status 422
  erb :login, locals: { error: 'That email and password don’t match.', email: email }
end

post '/logout' do
  session.clear
  redirect '/login'
end

get '/signup' do
  redirect '/' if current_user
  @title = 'Create an account'
  erb :signup, locals: { error: nil, form: {} }
end

post '/signup' do
  form = params.slice('name', 'email')
  password = params[:password].to_s
  user = User.new(name: form['name'].to_s.strip, email: form['email'].to_s.strip.downcase, signup_ip: request.ip)
  recent = User.where(signup_ip: request.ip).where(Sequel[:created_at] > Time.now - 86_400).count
  # "website" is a hidden field people never see; bots fill it in.
  error = if !params[:website].to_s.empty? || recent >= SIGNUPS_PER_IP_PER_DAY then "Sign-up isn't available right now. Try again later."
          elsif !user.valid? then first_error(user)
          elsif password.length < 8 then 'Use at least 8 characters for your password.'
          elsif password.bytesize > 72 then 'Use a password of 72 characters or fewer.'
          elsif password != params[:confirm].to_s then "The passwords don't match."
          end
  if error
    APP_LOGGER.warn("Sign-up refused from #{request.ip}: #{error}")
    @title = 'Create an account'
    status 422
    return erb :signup, locals: { error: error, form: form }
  end

  user.password = password
  user.save
  APP_LOGGER.info("Sign-up: user #{user.id} from #{request.ip}")
  session.clear
  session[:user_id] = user.id
  notice 'success', "Welcome, #{user.first_name}. Start by entering what you have today."
  redirect '/'
end

# --- Home ---------------------------------------------------------------------

get '/' do
  erb :home, locals: {
    safe: plan.safe_to_spend, moves: plan.suggested_moves, unbanked: plan.unbanked_cash,
    cooled: plan.cooled_items, maturities: plan.maturities, emergency: plan.emergency,
    buy: plan.buy_list, overdrawn: plan.overdrawn,
    recent: Transaction.where(user_id: current_user.id).latest_first.limit(5).eager(entries: [:pot, :account]).all,
    started: Transaction.where(user_id: current_user.id).any?,
    inbox_count: InboxMessage.where(user_id: current_user.id, status: 'pending').count
  }
end

get '/add' do
  @title = 'Add'
  @back = '/'
  erb :add
end

get '/more' do
  @title = 'More'
  erb :more
end

get '/learn' do
  @title = 'Investing in Ghana'
  @back = '/invest'
  erb :learn
end

# --- Income -------------------------------------------------------------------

helpers do
  def income_page(form, error: nil)
    status 422 if error
    @title = 'Money in'
    @back = '/'
    used = Transaction.where(user_id: current_user.id, kind: 'income').exclude(source: nil)
                      .reverse(:id).limit(30).select_map(:source)
    room = plan.living_room
    erb :income, locals: {
      form: form, error: error, sources: (used + INCOME_SOURCES).uniq.reject { |s| s == 'Unrecorded' }.first(7),
      split: { pots: current_user.pots.map { |p| { id: p.id, name: p.name, kind: p.kind, percent: p.percent } }, room: room }
    }
  end
end

get '/income/new' do
  income_page({
    'amount' => params[:amount], 'account_id' => (params[:account_id] || default_account_id('income')).to_s,
    'occurred_on' => params[:on] || today.iso8601, 'source' => params[:source], 'note' => params[:note],
    'mode' => 'split', 'pot_id' => current_user.pot('living').id.to_s, 'external_ref' => params[:ref],
    'inbox_id' => params[:inbox]
  })
end

post '/income' do
  form = params.slice('amount', 'account_id', 'occurred_on', 'source', 'note', 'mode', 'pot_id', 'external_ref', 'inbox_id')
  amount = Money.parse(form['amount'])
  account = find_account(form['account_id'])
  on = parse_date(form['occurred_on'])
  one_pot = form['mode'] == 'one'
  pot = one_pot ? find_pot(form['pot_id']) : nil
  error = if !amount&.positive? then 'Enter the amount you received, like 1500 or 1,500.00.'
          elsif account.nil? then 'Choose the account it came into.'
          elsif (problem = date_error(on)) then problem
          elsif one_pot && pot.nil? then 'Choose the pot it all goes to.'
          end
  return income_page(form, error: error) if error

  overflow = pot ? 0 : plan.split(amount, on)[:overflow]
  txn = ledger.income(amount: amount, account: account, on: on, source: blank_to_nil(form['source']),
                      note: blank_to_nil(form['note']), pot: pot, external_ref: blank_to_nil(form['external_ref']))
  close_inbox_message(form['inbox_id'], txn)
  parts = txn.entries.map { |e| "#{e.pot.name} #{Money.format(e.amount, short: true)}" }.join(' · ')
  covered = " #{current_user.pot('living').name}'s target for the month is met, so #{cedis(overflow, short: true)} of its share went to #{current_user.pot('future').name}." if overflow.positive?
  notice 'success', "#{cedis(amount)} in. #{parts}.#{covered}"
  redirect '/'
end

# --- Spending -----------------------------------------------------------------

helpers do
  def spend_page(form, error: nil)
    status 422 if error
    @title = 'Money out'
    @back = '/'
    erb :spend, locals: { form: form, error: error, safe: plan.safe_to_spend }
  end
end

get '/spend/new' do
  spend_page({
    'amount' => params[:amount], 'pot_id' => (params[:pot_id] || current_user.pot('enjoy').id).to_s,
    'account_id' => (params[:account_id] || default_account_id('spend')).to_s,
    'occurred_on' => params[:on] || today.iso8601, 'note' => params[:note], 'external_ref' => params[:ref],
    'inbox_id' => params[:inbox]
  })
end

post '/spend' do
  form = params.slice('amount', 'pot_id', 'account_id', 'occurred_on', 'note', 'external_ref', 'inbox_id')
  amount = Money.parse(form['amount'])
  pot = find_pot(form['pot_id'])
  account = find_account(form['account_id'])
  on = parse_date(form['occurred_on'])
  error = if !amount&.positive? then 'Enter the amount you spent, like 25 or 25.50.'
          elsif pot.nil? then 'Choose the pot it came from.'
          elsif account.nil? then 'Choose the account you paid from.'
          else date_error(on)
          end
  return spend_page(form, error: error) if error

  txn = ledger.spend(amount: amount, pot: pot, account: account, on: on, note: blank_to_nil(form['note']),
                     external_ref: blank_to_nil(form['external_ref']))
  close_inbox_message(form['inbox_id'], txn)
  message = "Spent #{cedis(amount)} from #{pot.name}."
  if pot.kind == 'enjoy' && on == today
    left = Plan.new(current_user).safe_to_spend[:left]
    message += left.negative? ? " You're #{cedis(-left)} over today's share." : " #{cedis(left)} left to spend today."
  end
  notice 'success', message
  redirect '/'
end

# --- Moves between accounts ---------------------------------------------------

helpers do
  def move_page(form, error: nil)
    status 422 if error
    @title = 'Move money'
    @back = '/'
    erb :move, locals: { form: form, error: error, balances: balances_by_account }
  end
end

get '/move/new' do
  parts = (params[:parts] || {}).to_h
  parts[params[:pot_id].to_s] = params[:amount] if params[:pot_id]
  move_page({
    'from_id' => params[:from].to_s, 'to_id' => params[:to].to_s, 'parts' => parts, 'fee' => '',
    'fee_pot_id' => current_user.pot('living').id.to_s, 'occurred_on' => today.iso8601, 'note' => '',
    'inbox_id' => params[:inbox]
  })
end

post '/move' do
  form = params.slice('from_id', 'to_id', 'fee', 'fee_pot_id', 'occurred_on', 'note', 'inbox_id')
  form['parts'] = (params[:parts] || {}).to_h
  from = find_account(form['from_id'])
  to = find_account(form['to_id'])
  raw_parts = current_user.pots.to_h { |pot| [pot, form['parts'][pot.id.to_s].to_s.strip] }.reject { |_, raw| raw.empty? }
  parts = raw_parts.transform_values { |raw| Money.parse(raw) }
  fee = form['fee'].to_s.strip.empty? ? 0 : Money.parse(form['fee'])
  fee_pot = find_pot(form['fee_pot_id'])
  on = parse_date(form['occurred_on'])
  error = if from.nil? || to.nil? then 'Choose the account the money leaves and the one it goes to.'
          elsif from == to then 'Choose two different accounts.'
          elsif parts.value?(nil) then 'Enter amounts like 400 or 400.00.'
          elsif parts.values.sum.zero? then 'Enter how much of at least one pot is moving.'
          elsif fee.nil? then 'Enter the fee like 1.50, or leave it blank.'
          elsif fee.positive? && fee_pot.nil? then 'Choose the pot that pays the fee.'
          else date_error(on)
          end
  return move_page(form, error: error) if error

  parts.reject! { |_, value| value.zero? }
  txn = ledger.move(parts: parts, from: from, to: to, on: on, note: blank_to_nil(form['note']), fee: fee, fee_pot: fee_pot)
  close_inbox_message(form['inbox_id'], txn)
  notice 'success', "Moved #{cedis(parts.values.sum)} from #{from.name} to #{to.name}."
  redirect '/'
end

# --- Pot to pot ---------------------------------------------------------------

helpers do
  def shift_page(form, error: nil)
    status 422 if error
    @title = 'Pot to pot'
    @back = '/'
    erb :shift, locals: { form: form, error: error, balances: balances_by_account }
  end
end

get '/shift/new' do
  shift_page({
    'from_pot_id' => (params[:from] || current_user.pot('enjoy').id).to_s,
    'to_pot_id' => (params[:to] || current_user.pot('future').id).to_s,
    'account_id' => (params[:account_id] || default_account_id('spend')).to_s,
    'amount' => params[:amount], 'occurred_on' => today.iso8601, 'note' => params[:note]
  })
end

post '/shift' do
  form = params.slice('from_pot_id', 'to_pot_id', 'account_id', 'amount', 'occurred_on', 'note')
  from = find_pot(form['from_pot_id'])
  to = find_pot(form['to_pot_id'])
  account = find_account(form['account_id'])
  amount = Money.parse(form['amount'])
  on = parse_date(form['occurred_on'])
  error = if from.nil? || to.nil? then 'Choose both pots.'
          elsif from == to then 'Choose two different pots.'
          elsif account.nil? then 'Choose the account the money is in.'
          elsif !amount&.positive? then 'Enter the amount, like 50 or 50.00.'
          else date_error(on)
          end
  return shift_page(form, error: error) if error

  ledger.shift(amount: amount, from_pot: from, to_pot: to, account: account, on: on, note: blank_to_nil(form['note']))
  notice 'success', "Gave #{cedis(amount)} from #{from.name} to #{to.name}."
  redirect '/'
end

# --- Balance check ------------------------------------------------------------

helpers do
  def check_page(form, error: nil)
    status 422 if error
    @title = 'Check a balance'
    @back = '/'
    erb :check, locals: {
      form: form, error: error, balances: balances_by_account,
      totals: current_user.cash_accounts.to_h { |a| [a.id, plan.account_balance(a)] }
    }
  end
end

get '/check/new' do
  account = find_account(params[:account_id]) || current_user.cash_accounts.first
  check_page({ 'account_id' => account&.id.to_s, 'actual' => params[:actual],
               'pot_id' => current_user.pot('living').id.to_s, 'surplus' => 'pot' })
end

post '/check' do
  form = params.slice('account_id', 'actual', 'pot_id', 'surplus')
  account = find_account(form['account_id'])
  actual = Money.parse(form['actual'])
  pot = find_pot(form['pot_id'])
  error = if account.nil? then 'Choose the account you are checking.'
          elsif actual.nil? then 'Enter the balance your bank or MoMo shows, like 312.40.'
          elsif pot.nil? then 'Choose the pot the difference belongs to.'
          end
  return check_page(form, error: error) if error

  before = plan.account_balance(account)
  txn = ledger.check(account: account, actual: actual, pot: pot, on: today, as_income: form['surplus'] == 'income')
  difference = actual - before
  message = if txn.nil? then "#{account.name} matches at #{cedis(actual)}. All square."
            elsif difference.negative? then "Recorded #{cedis(-difference)} of unrecorded spending from #{pot.name}."
            elsif txn.kind == 'income' then "Split #{cedis(difference)} of unrecorded income across your pots."
            else "Added #{cedis(difference)} to #{pot.name}."
            end
  notice 'success', txn ? "#{message} #{account.name} now shows #{cedis(actual)}." : message
  redirect '/'
end

# --- Starting balances --------------------------------------------------------

get '/setup' do
  @title = 'Starting balances'
  @back = '/'
  erb :setup, locals: { values: {}, error: nil }
end

post '/setup' do
  values = (params[:balances] || {}).to_h
  rows = []
  invalid = false
  current_user.cash_accounts.each do |account|
    current_user.pots.each do |pot|
      raw = values.dig(account.id.to_s, pot.id.to_s).to_s.strip
      next if raw.empty?

      amount = Money.parse(raw)
      invalid ||= amount.nil?
      rows << [pot, account, amount] if amount&.positive?
    end
  end
  error = if invalid then 'Enter amounts like 1500 or 1,500.00.'
          elsif rows.empty? then 'Enter at least one amount.'
          end
  if error
    @title = 'Starting balances'
    @back = '/'
    status 422
    return erb :setup, locals: { values: values, error: error }
  end

  ledger.opening(rows, on: today)
  notice 'success', "Starting balances saved: #{cedis(rows.sum { |_, _, v| v })} in total."
  redirect '/'
end

# --- Activity -----------------------------------------------------------------

helpers do
  def find_txn!
    Transaction.first(id: params[:id].to_i, user_id: current_user.id) || halt(404, 'Not found')
  end
end

get '/activity' do
  month = parse_month(params[:month]) || Date.new(today.year, today.month, 1)
  pot = find_pot(params[:pot])
  account = current_user.accounts.find { |a| a.id == params[:account].to_i }
  kind = Transaction::KINDS.key?(params[:kind]) ? params[:kind] : nil
  dataset = Transaction.where(user_id: current_user.id, occurred_on: plan.month_range(month))
  dataset = dataset.where(id: Entry.where(pot_id: pot.id).select(:transaction_id)) if pot
  dataset = dataset.where(id: Entry.where(account_id: account.id).select(:transaction_id)) if account
  dataset = dataset.where(kind: kind) if kind
  first = Transaction.where(user_id: current_user.id).min(:occurred_on)
  first = Date.parse(first) if first.is_a?(String)
  @title = 'Activity'
  @back = '/more'
  erb :activity, locals: {
    month: month, pot: pot, account: account, kind: kind,
    days: dataset.latest_first.eager(:investment, entries: [:pot, :account]).all.group_by(&:occurred_on),
    months: first ? (0..).lazy.map { |i| Date.new(today.year, today.month, 1) << i }.take_while { |m| m >= Date.new(first.year, first.month, 1) }.to_a : [month]
  }
end

get '/transactions/:id' do
  txn = find_txn!
  @title = txn.kind_label
  @back = '/activity'
  erb :transaction, locals: { txn: txn }
end

post '/transactions/:id/delete' do
  txn = find_txn!
  unless deletable?(txn)
    notice 'error', "Undo this investment's later changes first, newest first."
    redirect "/transactions/#{txn.id}"
  end
  investment_id = txn.investment_id
  ledger.delete(txn)
  notice 'success', 'Deleted. Balances are back to how they were before it.'
  redirect investment_id && Investment[investment_id] ? "/invest/#{investment_id}" : '/activity'
end

# --- Buy List -----------------------------------------------------------------

helpers do
  def buy_page(form: {}, error: nil)
    status 422 if error
    @title = 'Buy List'
    items = BuyItem.where(user_id: current_user.id)
    erb :buy, locals: {
      form: form, error: error, list: plan.buy_list, balance: plan.pot_balance(current_user.pot('buy')),
      cooling: items.cooling.all, done: items.done.limit(20).all
    }
  end

  def find_item!
    BuyItem.first(id: params[:id].to_i, user_id: current_user.id) || halt(404, 'Not found')
  end

  def item_form_values(item)
    { 'name' => item.name, 'price' => Money.input(item.price), 'target_on' => item.target_on&.iso8601, 'note' => item.note }
  end

  def assign_item(item, form)
    item.set(name: form['name'].to_s.strip, price: Money.parse(form['price']),
             target_on: parse_date(form['target_on']), note: blank_to_nil(form['note']))
  end

  def renumber_list
    BuyItem.where(user_id: current_user.id).listed.all.each_with_index do |item, index|
      item.update(position: index + 1) unless item.position == index + 1
    end
  end
end

get '/buy' do
  buy_page
end

post '/buy' do
  form = params.slice('name', 'price', 'target_on', 'note', 'planned')
  item = assign_item(BuyItem.new(user_id: current_user.id), form)
  hours = current_user.cooling_hours
  if form['planned'] == '1' || hours.zero?
    item.set(status: 'listed', position: (BuyItem.where(user_id: current_user.id).max(:position) || 0) + 1)
  else
    item.set(status: 'cooling', cooling_until: Time.now + (hours * 3600))
  end
  return buy_page(form: form, error: first_error(item)) unless item.valid?

  item.save
  notice 'success', if item.status == 'listed' then "#{item.name} is on your list."
                    else "#{item.name} waits #{hours} hours. If you still want it then, it joins the list."
                    end
  redirect '/buy'
end

get '/buy/:id/edit' do
  item = find_item!
  @title = 'Edit item'
  @back = '/buy'
  erb :buy_edit, locals: { item: item, form: item_form_values(item), error: nil }
end

post '/buy/:id' do
  item = find_item!
  form = params.slice('name', 'price', 'target_on', 'note')
  assign_item(item, form)
  if item.valid?
    item.save
    notice 'success', 'Saved.'
    redirect '/buy'
  end
  @title = 'Edit item'
  @back = '/buy'
  status 422
  erb :buy_edit, locals: { item: item, form: form, error: first_error(item) }
end

post '/buy/:id/approve' do
  item = find_item!
  if item.cooled?
    item.update(status: 'listed', cooling_until: nil, position: (BuyItem.where(user_id: current_user.id).max(:position) || 0) + 1)
    notice 'success', "#{item.name} joined the list."
  else
    notice 'error', "#{item.name} is still cooling off."
  end
  redirect '/buy'
end

post '/buy/:id/drop' do
  item = find_item!
  item.update(status: 'dropped') if %w[cooling listed].include?(item.status)
  notice 'success', "Dropped #{item.name}. That's money kept."
  redirect params[:back] == 'home' ? '/' : '/buy'
end

post '/buy/:id/move' do
  item = find_item!
  renumber_list
  item.refresh
  listed = BuyItem.where(user_id: current_user.id).listed
  neighbour = params[:dir] == 'up' ? listed.where(position: item.position - 1).first : listed.where(position: item.position + 1).first
  if item.status == 'listed' && neighbour
    DB.transaction do
      position = item.position
      item.update(position: neighbour.position)
      neighbour.update(position: position)
    end
  end
  redirect '/buy'
end

post '/buy/:id/delete' do
  item = find_item!
  if item.status == 'bought'
    notice 'error', 'Bought items stay as history. Delete the purchase in Activity to undo it.'
  else
    item.destroy
    notice 'success', "Removed #{item.name}."
  end
  redirect '/buy'
end

helpers do
  def purchase_page(item, form, error: nil)
    status 422 if error
    @title = "Buy #{item.name}"
    @back = '/buy'
    filled = plan.buy_list[:items].find { |row| row[:item].id == item.id }&.dig(:filled) || 0
    erb :buy_purchase, locals: { item: item, form: form, error: error, filled: filled,
                                 balance: [plan.pot_balance(current_user.pot('buy')), 0].max }
  end
end

get '/buy/:id/purchase' do
  item = find_item!
  redirect '/buy' unless item.status == 'listed'
  purchase_page(item, { 'paid' => Money.input(item.price), 'account_id' => default_account_id('spend').to_s,
                        'occurred_on' => today.iso8601, 'cover_pot_id' => current_user.pot('enjoy').id.to_s })
end

post '/buy/:id/purchase' do
  item = find_item!
  redirect '/buy' unless item.status == 'listed'
  form = params.slice('paid', 'account_id', 'occurred_on', 'cover_pot_id')
  paid = Money.parse(form['paid'])
  account = find_account(form['account_id'])
  on = parse_date(form['occurred_on'])
  balance = [plan.pot_balance(current_user.pot('buy')), 0].max
  cover_pot = paid && paid > balance ? find_pot(form['cover_pot_id']) : nil
  error = if !paid&.positive? then 'Enter what you paid, like 250 or 250.00.'
          elsif account.nil? then 'Choose the account you paid from.'
          elsif paid > balance && (cover_pot.nil? || cover_pot.kind == 'buy') then 'Choose the pot that covers the rest.'
          else date_error(on)
          end
  return purchase_page(item, form, error: error) if error

  ledger.buy(item: item, paid: paid, account: account, on: on, cover_pot: cover_pot)
  notice 'success', "Bought #{item.name} for #{cedis(paid)}. Enjoy it."
  redirect '/buy'
end

# --- Investments --------------------------------------------------------------

helpers do
  def find_investment!
    Investment.first(id: params[:id].to_i, user_id: current_user.id) || halt(404, 'Not found')
  end

  def investment_form_page(form, error: nil, investment: nil)
    status 422 if error
    @title = investment ? 'Edit investment' : 'Add investment'
    @back = investment ? "/invest/#{investment.id}" : '/invest'
    erb :invest_form, locals: { form: form, error: error, investment: investment }
  end

  def investment_page(investment, error: nil, form: {})
    status 422 if error
    @title = investment.name
    @back = '/invest'
    erb :investment, locals: { investment: investment, error: error, form: form, history: investment.transactions_dataset.all }
  end

  # "18.5" or "18.5%" -> BigDecimal; blank -> nil; anything else -> false.
  def parse_rate(raw)
    value = raw.to_s.strip.delete('%')
    return nil if value.empty?

    value.match?(/\A\d{1,3}(\.\d{1,3})?\z/) ? BigDecimal(value) : false
  end

  # Fields an investment's details form sets (not its money).
  def assign_investment(investment, form)
    rate = parse_rate(form['rate'])
    investment.set(kind: form['kind'], name: blank_to_nil(form['name']), provider: blank_to_nil(form['provider']),
                   rate: rate || nil, started_on: parse_date(form['started_on']), matures_on: parse_date(form['matures_on']),
                   emergency: form['emergency'] == '1', note: blank_to_nil(form['note']))
    if investment.name.nil?
      days = investment.matures_on && investment.started_on && (investment.matures_on - investment.started_on).to_i
      investment.name = investment.kind == 'tbill' && days ? "#{days}-day T-bill" : investment.kind_label
    end
    rate == false ? 'Enter the rate as a number, like 18.5.' : nil
  end

  def investment_values(investment)
    {
      'kind' => investment.kind, 'name' => investment.name, 'provider' => investment.provider,
      'rate' => investment.rate&.to_s('F'), 'started_on' => investment.started_on&.iso8601,
      'matures_on' => investment.matures_on&.iso8601, 'emergency' => investment.emergency ? '1' : nil, 'note' => investment.note
    }
  end
end

get '/invest' do
  @title = 'Investments'
  investments = Investment.where(user_id: current_user.id)
  erb :invest, locals: { active: investments.active.all, closed: investments.closed.limit(20).all, emergency: plan.emergency }
end

get '/invest/new' do
  bank = current_user.cash_accounts.find { |a| a.kind == 'bank' } || current_user.cash_accounts.first
  investment_form_page({
    'kind' => params[:kind] || 'tbill', 'name' => params[:name], 'provider' => params[:provider], 'amount' => params[:amount],
    'from_id' => (params[:from] || bank&.id).to_s, 'rate' => '', 'started_on' => params[:on] || today.iso8601,
    'matures_on' => '', 'emergency' => params[:kind] == 'fund' ? '1' : nil, 'note' => ''
  })
end

post '/invest' do
  form = params.slice('kind', 'name', 'provider', 'amount', 'from_id', 'rate', 'started_on', 'matures_on', 'emergency', 'note')
  amount = Money.parse(form['amount'])
  held = form['from_id'] == 'held'
  from = held ? nil : find_account(form['from_id'])
  investment = Investment.new(user_id: current_user.id, status: 'active', principal: amount, value: amount)
  rate_error = assign_investment(investment, form)
  error = if !amount&.positive? then 'Enter the amount invested, like 5000 or 5,000.00.'
          elsif !held && from.nil? then 'Choose where the money came from.'
          elsif rate_error then rate_error
          elsif !investment.valid? then first_error(investment)
          else date_error(investment.started_on)
          end
  return investment_form_page(form, error: error) if error

  DB.transaction do
    investment.save
    ledger.open_investment(investment, from: from, on: investment.started_on)
  end
  notice 'success', "Added #{investment.name}: #{cedis(amount)}."
  redirect "/invest/#{investment.id}"
end

get '/invest/:id' do
  investment_page(find_investment!)
end

get '/invest/:id/edit' do
  investment = find_investment!
  investment_form_page(investment_values(investment), investment: investment)
end

post '/invest/:id' do
  investment = find_investment!
  form = params.slice('kind', 'name', 'provider', 'rate', 'started_on', 'matures_on', 'emergency', 'note')
  rate_error = assign_investment(investment, form)
  error = rate_error || (investment.valid? ? nil : first_error(investment))
  return investment_form_page(form, error: error, investment: investment) if error

  investment.save
  notice 'success', 'Saved.'
  redirect "/invest/#{investment.id}"
end

post '/invest/:id/value' do
  investment = find_investment!
  value = Money.parse(params[:value])
  return investment_page(investment, error: 'Enter what it is worth now, like 5250.00.', form: params) if value.nil? || !investment.active?

  txn = ledger.revalue(investment, value: value, on: today)
  notice 'success', txn ? "#{investment.name} is now worth #{cedis(value)}." : 'No change.'
  redirect "/invest/#{investment.id}"
end

post '/invest/:id/top-up' do
  investment = find_investment!
  amount = Money.parse(params[:amount])
  held = params[:from_id] == 'held'
  from = held ? nil : find_account(params[:from_id])
  on = parse_date(params[:occurred_on])
  error = if !investment.active? then 'This investment is closed.'
          elsif !amount&.positive? then 'Enter the amount added, like 500.'
          elsif !held && from.nil? then 'Choose where the money came from.'
          else date_error(on)
          end
  return investment_page(investment, error: error, form: params) if error

  ledger.top_up(investment, amount: amount, from: from, on: on)
  notice 'success', "Added #{cedis(amount)} to #{investment.name}."
  redirect "/invest/#{investment.id}"
end

post '/invest/:id/cash-out' do
  investment = find_investment!
  amount = Money.parse(params[:amount])
  to = find_account(params[:to_id])
  on = parse_date(params[:occurred_on])
  close = params[:close] == '1'
  error = if !investment.active? then 'This investment is already closed.'
          elsif !amount&.positive? then 'Enter the amount you received, like 5,250.00.'
          elsif to.nil? then 'Choose the account the money went into.'
          elsif !close && amount >= investment.value then "That's all of it. Tick “Close it” to take everything out."
          else date_error(on)
          end
  return investment_page(investment, error: error, form: params) if error

  ledger.cash_out(investment, amount: amount, to: to, on: on, close: close)
  if close && params[:rollover] == '1'
    notice 'success', "Closed with #{cedis(amount)}. Now record the new one."
    query = URI.encode_www_form(kind: investment.kind, provider: investment.provider, amount: Money.input(amount), from: to.id, on: on.iso8601)
    redirect "/invest/new?#{query}"
  end
  notice 'success', close ? "Closed #{investment.name}: #{cedis(amount)} into #{to.name}." : "Took #{cedis(amount)} out into #{to.name}."
  redirect "/invest/#{investment.id}"
end

post '/invest/:id/undo' do
  investment = find_investment!
  txn = Transaction.where(investment_id: investment.id).order(Sequel.desc(:id)).first
  ledger.delete(txn) if txn
  if Investment[investment.id]
    notice 'success', 'Undone.'
    redirect "/invest/#{investment.id}"
  end
  notice 'success', "Removed #{investment.name}."
  redirect '/invest'
end

# --- Monthly review -----------------------------------------------------------

get '/review' do
  this_month = Date.new(today.year, today.month, 1)
  month = parse_month(params[:month]) || this_month
  month = this_month if month > this_month
  @title = 'Monthly review'
  @back = '/more'
  erb :review, locals: { month: month, review: plan.review(month), this_month: this_month }
end

# --- SMS import ---------------------------------------------------------------

get '/import' do
  @title = 'Paste an SMS'
  @back = '/'
  erb :import, locals: { text: '', result: nil, error: nil }
end

post '/import' do
  @title = 'Paste an SMS'
  @back = '/'
  text = params[:text].to_s[0, 2000]
  result = SmsParser.parse(text)
  unless result[:amount]&.positive?
    status 422
    return erb :import, locals: { text: text, result: nil, error: "I couldn't find an amount in that message. Paste the whole SMS, including the GHS amount." }
  end

  message = InboxMessage.from_sms(current_user, text)
  account = sms_account(message.account_kind)
  erb :import, locals: {
    text: text, result: result, error: nil, account: account, duplicate: message.saved_already,
    links: inbox_links(message, account).merge(
      check: result[:balance] && "/check/new?#{URI.encode_www_form(account_id: account&.id, actual: Money.input(result[:balance]))}"
    )
  }
end

# --- SMS inbox ----------------------------------------------------------------

helpers do
  def find_message!
    InboxMessage.first(id: params[:id].to_i, user_id: current_user.id) || halt(404, 'Not found')
  end

  # The account an SMS most likely belongs to: the first MoMo or bank account,
  # going by its wording, else the usual one.
  def sms_account(kind)
    current_user.cash_accounts.find { |a| a.kind == kind } || find_account(default_account_id('spend'))
  end

  # Prefilled forms for an SMS, to change it before saving. A saved inbox
  # message rides along so saving the form marks it recorded.
  def inbox_links(message, account)
    common = { account_id: account&.id, on: message.occurred_on.iso8601, ref: message.ref_id, inbox: message.id }.compact
    notes = message.notes
    {
      income: "/income/new?#{URI.encode_www_form(common.merge(amount: Money.input(message.amount), note: notes[:in]))}",
      spend: "/spend/new?#{URI.encode_www_form(common.merge(amount: Money.input(message.spent), note: notes[:out]))}",
      move: "/move/new?#{URI.encode_www_form({ from: account&.id, inbox: message.id }.compact)}"
    }
  end

  # Marks the inbox message an entry was made from as recorded.
  def close_inbox_message(id, txn)
    return if id.to_s.empty?

    InboxMessage.first(id: id.to_i, user_id: current_user.id, status: 'pending')&.update(status: 'recorded', transaction_id: txn.id)
  end

  def inbox_url(token)
    "#{request.base_url}/sms/#{token}"
  end

  # The SMS a phone automation sent: a "text" field (form or JSON), or the
  # whole body when it came as plain text.
  def posted_sms
    request.body.rewind
    raw = request.body.read.to_s
    data = request.media_type == 'application/json' ? (JSON.parse(raw) rescue nil) : nil
    data = {} unless data.is_a?(Hash)
    text = params['text'] || params['message'] || data['text'] || data['message']
    text ||= raw unless request.media_type.to_s.match?(/form-urlencoded|multipart/)
    [text.to_s.strip[0, 2000], (params['from'] || data['from']).to_s.strip[0, 40]]
  end
end

# Where a phone sends money SMS (see /inbox/setup). The token in the address is
# the only key: no login, and plain-text replies for the automation's log.
post '/sms/:token' do
  content_type 'text/plain'
  token = params[:token].to_s
  user = token.length >= 24 ? User.first(inbox_token: token) : nil
  halt 404, 'Unknown inbox link.' unless user
  text, sender = posted_sms
  halt 400, 'No message text.' if text.empty?
  messages = InboxMessage.where(user_id: user.id)
  halt 429, 'Too many messages today.' if messages.where(Sequel[:created_at] > Time.now - 86_400).count >= INBOX_MESSAGES_PER_DAY

  message = InboxMessage.from_sms(user, text, sender: blank_to_nil(sender))
  halt 200, 'Ignored: no amount in this message, so it was not kept.' unless message
  repeat = messages.where(body: text).where(Sequel[:created_at] > Time.now - 86_400).any? ||
           (message.ref_id && (messages.where(ref_id: message.ref_id).any? || message.saved_already))
  halt 200, 'Already received.' if repeat

  message.save
  APP_LOGGER.info("SMS inbox: message #{message.id} for user #{user.id}")
  status 201
  "Saved #{cedis(message.amount)}. Confirm it in Ega."
end

get '/inbox' do
  @title = 'SMS inbox'
  @back = '/'
  messages = InboxMessage.where(user_id: current_user.id)
  erb :inbox, locals: { pending: messages.pending.all, done: messages.done.limit(15).all }
end

get '/inbox/setup' do
  @title = 'Set up the SMS inbox'
  @back = '/inbox'
  erb :inbox_setup, locals: { last: InboxMessage.where(user_id: current_user.id).order(Sequel.desc(:id)).first }
end

post '/inbox/token' do
  renewing = !current_user.inbox_token.nil?
  current_user.update(inbox_token: SecureRandom.urlsafe_base64(24))
  notice 'success', renewing ? 'New link made. Put it in your phone; the old one no longer works.' : 'Your private link is ready. Put it in your phone.'
  redirect '/inbox/setup'
end

post '/inbox/token/delete' do
  current_user.update(inbox_token: nil)
  notice 'success', 'SMS inbox turned off. The old link no longer works.'
  redirect '/inbox/setup'
end

post '/inbox/:id/record' do
  message = find_message!
  redirect '/inbox' unless message.status == 'pending'
  as = %w[in out].include?(params[:as]) ? params[:as] : message.direction
  account = find_account(params[:account_id])
  pot = find_pot(params[:pot_id])
  error = if as.nil? then 'Choose whether it was money in or money out.'
          elsif account.nil? then 'Choose the account.'
          elsif as == 'out' && pot.nil? then 'Choose the pot the spending came from.'
          end
  if error
    notice 'error', error
    redirect "/inbox#m-#{message.id}"
  end

  notes = message.notes
  txn = if as == 'in'
          ledger.income(amount: message.amount, account: account, on: message.occurred_on,
                        note: blank_to_nil(notes[:in]), external_ref: message.ref_id)
        else
          ledger.spend(amount: message.spent, pot: pot, account: account, on: message.occurred_on,
                       note: blank_to_nil(notes[:out]), external_ref: message.ref_id)
        end
  message.update(status: 'recorded', transaction_id: txn.id)
  notice 'success', as == 'in' ? "Split #{cedis(message.amount)} across your pots." : "Saved #{cedis(message.spent)} from #{pot.name}."
  redirect '/inbox'
end

post '/inbox/:id/dismiss' do
  message = find_message!
  message.update(status: 'dismissed') if message.status == 'pending'
  redirect '/inbox'
end

post '/inbox/:id/restore' do
  message = find_message!
  message.update(status: 'pending') if message.status == 'dismissed'
  redirect '/inbox'
end

# --- Settings -----------------------------------------------------------------

get '/settings' do
  @title = 'Settings'
  @back = '/more'
  erb :settings, locals: { balances: current_user.accounts.to_h { |a| [a.id, plan.account_balance(a)] } }
end

post '/settings/plan' do
  user = current_user
  payday = params[:payday].to_s.strip
  target = params[:living_target].to_s.strip
  user.set(payday: payday.empty? ? nil : payday.to_i, emergency_months: params[:emergency_months].to_i,
           living_target: target.empty? ? nil : Money.parse(target), cooling_hours: params[:cooling_hours].to_i)
  if !target.empty? && user.living_target.nil?
    notice 'error', 'Enter the living target like 3000 or 3,000.00, or leave it blank.'
  elsif user.valid?
    user.save
    notice 'success', 'Plan saved.'
  else
    notice 'error', first_error(user)
  end
  redirect '/settings#plan'
end

post '/settings/pots' do
  pots = current_user.pots
  pots.each do |pot|
    values = (params[:pots] || {}).to_h.fetch(pot.id.to_s, {})
    home = values['home_account_id'].to_s
    pot.set(name: values['name'].to_s.strip, percent: Integer(values['percent'].to_s.strip, exception: false) || -1,
            home_account_id: home.empty? ? nil : find_account(home)&.id)
  end
  total = pots.sum(&:percent)
  invalid = pots.find { |pot| !pot.valid? }
  if invalid
    notice 'error', "#{invalid.name.empty? ? 'A pot' : invalid.name}: #{first_error(invalid).sub(/\A./, &:downcase)}"
  elsif total != 100
    notice 'error', "The shares add up to #{total}%. They need to add up to 100%."
  else
    DB.transaction { pots.each(&:save) }
    notice 'success', 'Pots saved. The next income splits the new way.'
  end
  redirect '/settings#pots'
end

post '/settings/accounts' do
  account = Account.new(user_id: current_user.id, name: params[:name].to_s.strip, kind: params[:kind].to_s)
  if account.valid? && Account::KINDS.key?(account.kind)
    account.save
    notice 'success', "Added #{account.name}."
  else
    notice 'error', first_error(account) || 'Choose bank, MoMo or cash.'
  end
  redirect '/settings#accounts'
end

post '/settings/accounts/:id' do
  account = current_user.accounts.find { |a| a.id == params[:id].to_i } || halt(404, 'Not found')
  account.name = params[:name].to_s.strip
  account.kind = params[:kind] if Account::KINDS.key?(params[:kind]) && !account.investment?
  if account.valid?
    account.save
    notice 'success', 'Saved.'
  else
    notice 'error', first_error(account)
  end
  redirect '/settings#accounts'
end

post '/settings/accounts/:id/archive' do
  account = current_user.accounts.find { |a| a.id == params[:id].to_i } || halt(404, 'Not found')
  home_of = current_user.pots.select { |p| p.home_account_id == account.id }
  if account.investment?
    notice 'error', 'The Investments account stays.'
  elsif !plan.account_balance(account).zero?
    notice 'error', "#{account.name} still holds #{cedis(plan.account_balance(account))}. Move it out first."
  elsif home_of.any?
    notice 'error', "#{home_of.map(&:name).join(' and ')} live in #{account.name}. Choose another home under Pots first."
  else
    account.update(archived_at: Time.now)
    notice 'success', "Archived #{account.name}."
  end
  redirect '/settings#accounts'
end

post '/settings/accounts/:id/restore' do
  account = current_user.accounts.find { |a| a.id == params[:id].to_i } || halt(404, 'Not found')
  account.update(archived_at: nil)
  notice 'success', "#{account.name} is back."
  redirect '/settings#accounts'
end

post '/settings/profile' do
  user = current_user
  user.set(name: params[:name].to_s.strip, email: params[:email].to_s.strip.downcase)
  if user.valid?
    user.save
    notice 'success', 'Saved.'
  else
    notice 'error', first_error(user)
  end
  redirect '/settings#profile'
end

post '/settings/password' do
  user = current_user
  if !user.authenticate(params[:current].to_s)
    notice 'error', 'Your current password is not right.'
  elsif params[:new].to_s.length < 8
    notice 'error', 'Use at least 8 characters for the new password.'
  elsif params[:new] != params[:confirm]
    notice 'error', "The new passwords don't match."
  else
    user.password = params[:new]
    user.save
    notice 'success', 'Password changed.'
  end
  redirect '/settings#password'
end

not_found do
  return body if request.path_info.start_with?('/sms/')

  @title = 'Not found'
  @back = '/'
  erb :not_found
end

# In production, visitors see this instead of a backtrace; the details go to
# log/application.log.
error do
  failure = env['sinatra.error']
  APP_LOGGER.error("#{failure.class}: #{failure.message}\n#{failure.backtrace&.first(15)&.join("\n")}")
  @title = 'Something went wrong'
  @back = '/'
  erb :error
end
