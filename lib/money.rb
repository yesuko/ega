# Amounts are kept as whole pesewas (GH₵ 1 = 100) so sums never drift.
module Money
  # "1,200.50", "1200.5", "GHS 50" -> 120050; blank or malformed -> nil.
  def self.parse(raw)
    value = raw.to_s.gsub(/GH[S₵¢C]|₵|¢|[,\s]/i, '')
    return nil unless value.match?(/\A\d+(\.\d{1,2})?\z/)

    whole, fraction = value.split('.')
    (whole.to_i * 100) + fraction.to_s.ljust(2, '0').to_i
  end

  # 120050 -> "1,200.50"; short: true drops ".00".
  def self.format(pesewas, short: false)
    cedis, pesewas_part = pesewas.to_i.abs.divmod(100)
    text = cedis.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
    text += ".#{pesewas_part.to_s.rjust(2, '0')}" unless short && pesewas_part.zero?
    pesewas.to_i.negative? ? "-#{text}" : text
  end

  # For prefilling form inputs: 120050 -> "1200.50", nil -> "".
  def self.input(pesewas)
    pesewas.nil? ? '' : format(pesewas).delete(',')
  end
end
