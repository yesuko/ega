require 'test_helper'

class SmsParserTest < Minitest::Test
  TODAY = Date.new(2026, 10, 20)

  def parse(text)
    SmsParser.parse(text, today: TODAY)
  end

  def test_mtn_payment_received
    sms = parse('Payment received for GHS 50.00 from JOHN DOE Current Balance: GHS 120.50 . Available Balance: GHS 120.50. ' \
                'Reference: rent. Transaction ID: 41234567890. Fee charged: GHS0.00 TAX charged: GHS 0.')
    assert_equal [:in, 5_000, 12_050, 'JOHN DOE', 'rent', '41234567890'],
                 sms.values_at(:direction, :amount, :balance, :counterparty, :reference, :ref_id)
    assert_equal 'MTN MoMo', sms[:network][:name]
  end

  def test_mtn_payment_made_with_fee
    sms = parse('Payment made for GHS 20.00 to KOFI MENSAH. Current Balance: GHS 100.50. Available Balance: GHS 100.50. ' \
                'Reference: 1. Transaction ID: 41234567891. Fee charged: GHS0.20, Tax Charged GHS 0.00.')
    assert_equal [:out, 2_000, 20, 'KOFI MENSAH'], sms.values_at(:direction, :amount, :fee, :counterparty)
  end

  def test_telecel_sent
    sms = parse('0001234567 Confirmed. GHS50.00 sent to 0201234567 JOHN DOE on 2026-10-12 at 10:00. ' \
                'Your Telecel Cash balance is GHS100.00. Fee GHS0.50')
    assert_equal [:out, 5_000, 50, 10_000, '0001234567', Date.new(2026, 10, 12)],
                 sms.values_at(:direction, :amount, :fee, :balance, :ref_id, :on)
    assert_equal 'Telecel Cash', sms[:network][:name]
  end

  def test_bank_credit_and_debit
    credit = parse('Your account 12******34 has been credited with GHS 1,000.00 on 01-Oct-2026. Desc: SALARY OCT. Avail Bal: GHS 5,200.00')
    assert_equal [:in, 100_000, 520_000, 'SALARY OCT', Date.new(2026, 10, 1)],
                 credit.values_at(:direction, :amount, :balance, :description, :on)
    debit = parse('Debit Alert! Acct: 12**34 Amt: GHS 100.00 Desc: POS PURCHASE SHOPRITE Avail Bal: GHS 400.00 Date: 15/10/2026')
    assert_equal [:out, 10_000, 'POS PURCHASE SHOPRITE', Date.new(2026, 10, 15), 'bank'],
                 debit.values_at(:direction, :amount, :description, :on) + [debit[:network][:kind]]
  end

  def test_ignores_future_dates_and_text_without_amounts
    assert_nil parse('You have received GHS 5.00 from AMA on 2027-01-01.')[:on]
    assert_nil parse('hello there')[:amount]
  end
end
