require 'test_helper'
require 'rack/test'
require File.expand_path('../app', __dir__)

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def sign_up(name: 'Ama', email: 'ama@example.com', password: 'password123', confirm: nil, ip: '10.0.0.1', **extra)
    post '/signup', { name: name, email: email, password: password, confirm: confirm || password }.merge(extra), 'REMOTE_ADDR' => ip
  end

  def test_visitors_are_sent_to_log_in_but_can_sign_up
    get '/'
    assert_equal 302, last_response.status
    assert_match %r{/login\z}, last_response.location
    get '/signup'
    assert_equal 200, last_response.status
  end

  def test_sign_up_creates_an_account_and_logs_in
    sign_up(name: 'Ama Owusu', email: 'Ama@Example.com ')
    assert_equal 302, last_response.status
    user = User.first(email: 'ama@example.com')
    assert_equal ['Ama Owusu', '10.0.0.1', 4, 4], [user.name, user.signup_ip, user.pots.size, user.accounts.size]
    follow_redirect!
    assert_includes last_response.body, 'Welcome, Ama'
    assert_includes last_response.body, 'Start with what you have now'
  end

  def test_home_shows_a_simplified_safe_to_spend_summary_and_quote
    sign_up
    user = User.first(email: 'ama@example.com')
    momo = user.accounts.find { |a| a.name == 'MoMo' }
    post '/income', amount: '2000', account_id: momo.id, mode: 'split', occurred_on: Date.today.iso8601
    get '/'
    body = last_response.body
    assert_includes body, 'Safe to spend today'
    assert body.index('Safe to spend today') < body.index('Money quote'), 'the quote comes after the card'
    bar = ->(html) { html[/class="meter single-meter"><i style="width: (\d+)%"/, 1].to_i }
    assert_equal 100, bar.call(body) # nothing spent yet

    post '/spend', amount: '10', pot_id: user.pot('living').id, account_id: momo.id, occurred_on: Date.today.iso8601
    get '/'
    assert_operator bar.call(last_response.body), :<, 100 # each spend shortens it
  end

  def test_money_quote_can_be_turned_off_in_settings
    sign_up
    get '/settings'
    # An unticked box sends nothing, so a hidden field before it sends 0.
    assert_match(/name="show_money_quote" value="0">.*name="show_money_quote" value="1"/m, last_response.body)
    post '/settings/plan', show_money_quote: '0'
    assert_equal 302, last_response.status
    get '/'
    refute_includes last_response.body, 'Money quote'
  end

  def test_login_shows_the_quote_after_the_form_and_sign_up_none
    get '/login'
    assert last_response.body.index('Log in</button>') < last_response.body.index('Money quote')
    get '/signup'
    refute_includes last_response.body, 'Money quote'
  end

  def test_sign_up_checks_the_details
    sign_up
    clear_cookies
    sign_up(email: 'AMA@example.com')
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'Email already has an account'
    sign_up(email: 'kofi@example.com', password: 'short')
    assert_includes last_response.body, 'at least 8 characters'
    sign_up(email: 'kofi@example.com', confirm: 'different123')
    assert_includes last_response.body, 'match'
    sign_up(email: 'not-an-email')
    assert_includes last_response.body, 'look like an email address'
    assert_equal 1, User.count
  end

  def test_bots_and_bulk_sign_ups_are_refused
    sign_up(website: 'https://spam.example')
    assert_equal 422, last_response.status
    assert_equal 0, User.count

    5.times do |i|
      clear_cookies
      sign_up(email: "person#{i}@example.com", ip: '10.9.9.9')
      assert_equal 302, last_response.status
    end
    clear_cookies
    sign_up(email: 'person6@example.com', ip: '10.9.9.9')
    assert_equal 422, last_response.status
    sign_up(email: 'person6@example.com', ip: '10.9.9.10')
    assert_equal 302, last_response.status
  end

  def test_users_cannot_see_or_change_each_others_data
    sign_up(email: 'ama@example.com')
    ama = User.first(email: 'ama@example.com')
    momo = ama.accounts.find { |a| a.name == 'MoMo' }
    post '/income', amount: '1234', account_id: momo.id, source: 'Secret salary', mode: 'split', occurred_on: Date.today.iso8601
    post '/buy', name: 'Private wish', price: '500', planned: '1'
    post '/invest', kind: 'fund', name: 'Hidden fund', amount: '300', from_id: 'held', started_on: Date.today.iso8601
    txn = Transaction.first(user_id: ama.id, kind: 'income')
    item = BuyItem.first(user_id: ama.id)
    investment = Investment.first(user_id: ama.id)
    assert txn && item && investment

    clear_cookies
    sign_up(name: 'Kofi', email: 'kofi@example.com', ip: '10.0.0.2')
    get '/'
    refute_includes last_response.body, '1,234'
    get '/activity'
    refute_includes last_response.body, 'Secret salary'
    get '/buy'
    refute_includes last_response.body, 'Private wish'
    get '/invest'
    refute_includes last_response.body, 'Hidden fund'

    [[:get, "/transactions/#{txn.id}"], [:post, "/transactions/#{txn.id}/delete"], [:get, "/buy/#{item.id}/edit"],
     [:post, "/buy/#{item.id}/drop"], [:post, "/buy/#{item.id}/delete"], [:get, "/invest/#{investment.id}"],
     [:post, "/invest/#{investment.id}/undo"], [:post, "/settings/accounts/#{momo.id}/archive"]].each do |verb, path|
      send(verb, path)
      assert_equal 404, last_response.status, "#{verb.upcase} #{path}"
    end

    post '/spend', amount: '10', pot_id: ama.pot('enjoy').id, account_id: momo.id, occurred_on: Date.today.iso8601
    assert_equal 422, last_response.status
    assert Transaction[txn.id] && BuyItem[item.id].status == 'listed' && Investment[investment.id]
    assert_equal cedis(1234) + cedis(300), Plan.new(ama).total
  end
end
