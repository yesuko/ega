require 'test_helper'
require 'rack/test'
require File.expand_path('../app', __dir__)

class NavigationTest < Minitest::Test
  include Rack::Test::Methods

  SMS = 'Payment for GHS10.00 to MTN BUNDLE .Current Balance: GHS 1500.00. Transaction Id: 92000000001.'

  def app
    Sinatra::Application
  end

  def setup
    post '/signup', { name: 'Ama', email: 'ama@example.com', password: 'password123', confirm: 'password123' }, 'REMOTE_ADDR' => '10.0.0.1'
    @user = User.first(email: 'ama@example.com')
    @momo = @user.accounts.find { |a| a.name == 'MoMo' }
  end

  def back_arrow
    last_response.body[/<a class="icon-btn" href="([^"]*)" aria-label="Back">/, 1]&.gsub('&amp;', '&')
  end

  def spend(**extra)
    post '/spend', { amount: '10', pot_id: @user.pot('living').id, account_id: @momo.id, occurred_on: Date.today.iso8601 }.merge(extra)
    Transaction.where(user_id: @user.id).order(:id).last
  end

  def test_an_entry_opened_from_the_inbox_goes_back_to_the_inbox
    post '/inbox/token'
    post "/sms/#{@user.refresh.inbox_token}", text: SMS
    message = InboxMessage.first
    post "/inbox/#{message.id}/record", as: 'out', account_id: @momo.id, pot_id: @user.pot('living').id
    get '/inbox'
    link = last_response.body[%r{href="(/transactions/\d+\?back=[^"]+)"}, 1]
    assert_equal "/transactions/#{message.refresh.transaction_id}?back=%2Finbox", link

    get link
    assert_equal '/inbox', back_arrow
    post "/transactions/#{message.transaction_id}/delete", back: '/inbox'
    assert_equal '/inbox', URI(last_response.location).path
  end

  def test_entries_default_to_activity_and_activity_rows_remember_their_filters
    txn = spend
    get "/transactions/#{txn.id}"
    assert_equal '/activity', back_arrow

    get "/activity?pot=#{@user.pot('living').id}"
    link = last_response.body[%r{href="(/transactions/#{txn.id}[^"]*)"}, 1].gsub('&amp;', '&')
    get link
    assert_equal "/activity?pot=#{@user.pot('living').id}", back_arrow
  end

  def test_activity_opened_from_home_goes_back_home
    spend
    get '/'
    assert_includes last_response.body, 'href="/activity?back=%2F"'
    get '/activity?back=%2F'
    assert_equal '/', back_arrow
    get '/activity'
    assert_equal '/more', back_arrow
  end

  def test_change_first_from_the_inbox_returns_to_the_inbox_after_saving
    get '/spend/new?back=%2Finbox'
    assert_equal '/inbox', back_arrow
    assert_includes last_response.body, 'name="back" value="/inbox"'
    spend(back: '/inbox')
    assert_equal '/inbox', URI(last_response.location).path
    spend
    assert_equal '/', URI(last_response.location).path
  end

  def test_inbox_actions_keep_the_inbox_back_arrow
    post '/inbox/token'
    post "/sms/#{@user.refresh.inbox_token}", text: SMS
    message = InboxMessage.first
    post "/inbox/#{message.id}/dismiss", back: '/more'
    assert_equal '/inbox?back=%2Fmore', last_response.location.sub(%r{\Ahttps?://[^/]+}, '')
  end

  def test_back_links_to_other_sites_are_ignored
    txn = spend
    ['//evil.example', 'https://evil.example', '/\\evil.example', "/ok\r\nSet-Cookie: x=1", 'javascript:alert(1)'].each do |bad|
      get "/transactions/#{txn.id}", back: bad
      assert_equal '/activity', back_arrow, bad.inspect
    end
    post '/spend', amount: '5', pot_id: @user.pot('living').id, account_id: @momo.id, occurred_on: Date.today.iso8601, back: '//evil.example'
    assert_equal '/', URI(last_response.location).path
    assert_equal 'example.org', URI(last_response.location).host
  end
end
