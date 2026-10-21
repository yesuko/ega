require 'test_helper'

class MoneyTest < Minitest::Test
  def test_parse_reads_cedis_into_pesewas
    assert_equal 120_050, Money.parse('1,200.50')
    assert_equal 120_050, Money.parse('1200.5')
    assert_equal 5_000, Money.parse('GHS 50')
    assert_equal 5_000, Money.parse('GH₵50.00')
    assert_equal 7, Money.parse('0.07')
  end

  def test_parse_rejects_anything_else
    [nil, '', 'abc', '1.234', '-5', '12a'].each { |raw| assert_nil Money.parse(raw), raw.inspect }
  end

  def test_format
    assert_equal '1,200.50', Money.format(120_050)
    assert_equal '1,200', Money.format(120_000, short: true)
    assert_equal '1,200.50', Money.format(120_050, short: true)
    assert_equal '-20.50', Money.format(-2_050)
    assert_equal '0.00', Money.format(0)
    assert_equal '1,000,000.00', Money.format(100_000_000)
  end

  def test_input
    assert_equal '', Money.input(nil)
    assert_equal '1200.50', Money.input(120_050)
  end
end
