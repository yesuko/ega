require 'test_helper'
require 'rack/test'
require File.expand_path('../app', __dir__)

class InboxTest < Minitest::Test
  include Rack::Test::Methods

  RECEIVED = 'Payment received for GHS 50.00 from JOHN DOE Current Balance: GHS 120.50 . Available Balance: GHS 120.50. ' \
             'Reference: rent. Transaction ID: 41234567890. Fee charged: GHS0.00'
  PAID = 'Payment made for GHS 20.00 to KOFI MENSAH. Current Balance: GHS 100.50. Available Balance: GHS 100.50. ' \
         'Reference: 1. Transaction ID: 41234567891. Fee charged: GHS0.20, Tax Charged GHS 0.00.'

  def app
    Sinatra::Application
  end

  # Signs up (and stays logged in), turns the inbox on and returns the user.
  def user_with_inbox(email: 'ama@example.com', ip: '10.0.0.1')
    post '/signup', { name: 'Ama', email: email, password: 'password123', confirm: 'password123' }, 'REMOTE_ADDR' => ip
    post '/inbox/token'
    User.first(email: email)
  end

  def forward(user, text, **options)
    post "/sms/#{user.inbox_token}", { text: text }.merge(options)
  end

  def test_unknown_links_are_refused
    post '/sms/short', text: RECEIVED
    assert_equal 404, last_response.status
    post "/sms/#{'x' * 32}", text: RECEIVED
    assert_equal 404, last_response.status
    assert_equal 'Unknown inbox link.', last_response.body
  end

  def test_phone_can_send_a_form_plain_text_or_json
    user = user_with_inbox
    forward(user, RECEIVED, from: 'MobileMoney')
    assert_equal 201, last_response.status
    message = InboxMessage.first(user_id: user.id)
    assert_equal ['in', 5_000, 'JOHN DOE', 'rent', '41234567890', 'momo', 'MobileMoney', 'pending'],
                 message.values.values_at(:direction, :amount, :counterparty, :detail, :ref_id, :account_kind, :sender, :status)

    post "/sms/#{user.inbox_token}", PAID, 'CONTENT_TYPE' => 'text/plain'
    assert_equal 201, last_response.status
    post "/sms/#{user.inbox_token}", JSON.generate(text: PAID.sub('41234567891', '41234567892')), 'CONTENT_TYPE' => 'application/json'
    assert_equal 201, last_response.status
    assert_equal 3, InboxMessage.where(user_id: user.id).count
  end

  def test_non_money_texts_are_not_kept_and_repeats_are_skipped
    user = user_with_inbox
    forward(user, 'Your OTP is 4821. Do not share it.')
    assert_equal 200, last_response.status
    assert_equal 0, InboxMessage.count

    forward(user, RECEIVED)
    forward(user, RECEIVED)
    assert_equal 'Already received.', last_response.body
    forward(user, RECEIVED.sub('JOHN DOE', 'J. DOE'))
    assert_equal 'Already received.', last_response.body
    assert_equal 1, InboxMessage.count

    Transaction.create(user_id: user.id, kind: 'income', amount: 100, occurred_on: Date.today, external_ref: '41234567891', created_at: Time.now)
    forward(user, PAID)
    assert_equal 'Already received.', last_response.body
  end

  def test_money_in_is_split_with_one_tap
    user = user_with_inbox
    forward(user, RECEIVED)
    message = InboxMessage.first
    momo = user.accounts.find { |a| a.name == 'MoMo' }
    get '/inbox'
    assert_includes last_response.body, 'JOHN DOE'

    post "/inbox/#{message.id}/record", as: 'in', account_id: momo.id
    message.refresh
    txn = Transaction[message.transaction_id]
    assert_equal ['recorded', 'income', 5_000, '41234567890'], [message.status, txn.kind, txn.amount, txn.external_ref]
    assert_equal({ 'future' => 1_000, 'buy' => 500, 'living' => 2_500, 'enjoy' => 1_000 },
                 txn.entries.to_h { |e| [e.pot.kind, e.amount] })
  end

  def test_spending_needs_a_pot_and_includes_the_fee
    user = user_with_inbox
    forward(user, PAID)
    message = InboxMessage.first
    momo = user.accounts.find { |a| a.name == 'MoMo' }

    post "/inbox/#{message.id}/record", as: 'out', account_id: momo.id
    assert_equal 'pending', message.refresh.status

    post "/inbox/#{message.id}/record", as: 'out', account_id: momo.id, pot_id: user.pot('enjoy').id
    txn = Transaction[message.refresh.transaction_id]
    assert_equal ['recorded', 'spend', 2_020], [message.status, txn.kind, txn.amount]
    assert_equal user.pot('enjoy').id, txn.entries.first.pot_id
  end

  def test_saving_the_change_first_form_closes_the_message
    user = user_with_inbox
    forward(user, PAID)
    message = InboxMessage.first
    post '/spend', amount: '25', pot_id: user.pot('living').id, account_id: user.accounts.find { |a| a.name == 'MoMo' }.id,
                   occurred_on: Date.today.iso8601, external_ref: message.ref_id, inbox_id: message.id
    assert_equal ['recorded', 2_500], [message.refresh.status, Transaction[message.transaction_id].amount]
  end

  def test_deleting_the_saved_entry_puts_the_sms_back
    user = user_with_inbox
    forward(user, RECEIVED)
    message = InboxMessage.first
    post "/inbox/#{message.id}/record", as: 'in', account_id: user.accounts.find { |a| a.name == 'MoMo' }.id
    get "/transactions/#{message.refresh.transaction_id}"
    assert_includes last_response.body, 'goes back there'

    post "/transactions/#{message.transaction_id}/delete"
    assert_equal ['pending', nil], [message.refresh.status, message.transaction_id]
    assert_equal 0, Plan.new(user).total
    post "/inbox/#{message.id}/record", as: 'in', account_id: user.accounts.find { |a| a.name == 'MoMo' }.id
    assert_equal 'recorded', message.refresh.status
  end

  def test_dismiss_and_put_back
    user = user_with_inbox
    forward(user, RECEIVED)
    message = InboxMessage.first
    post "/inbox/#{message.id}/dismiss"
    assert_equal 'dismissed', message.refresh.status
    post "/inbox/#{message.id}/restore"
    assert_equal 'pending', message.refresh.status
    assert_equal 0, Transaction.where(user_id: user.id).count
  end

  def test_turning_off_or_renewing_the_link
    user = user_with_inbox
    old = user.inbox_token
    post '/inbox/token'
    refute_equal old, user.refresh.inbox_token
    post "/sms/#{old}", text: RECEIVED
    assert_equal 404, last_response.status
    post '/inbox/token/delete'
    assert_nil user.refresh.inbox_token
  end

  def test_others_cannot_see_or_act_on_my_inbox
    ama = user_with_inbox
    forward(ama, RECEIVED)
    message = InboxMessage.first
    clear_cookies
    user_with_inbox(email: 'kofi@example.com', ip: '10.0.0.2')
    get '/inbox'
    refute_includes last_response.body, 'JOHN DOE'
    %w[record dismiss restore].each do |action|
      post "/inbox/#{message.id}/#{action}", as: 'in', account_id: ama.accounts.first.id
      assert_equal 404, last_response.status, action
    end
    assert_equal 'pending', message.refresh.status
  end
end
