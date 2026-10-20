require 'date'

# Reads a pasted MoMo or bank alert SMS into the fields of an income or
# spending entry. Networks and banks word these differently and change them
# often, so this looks for keywords and amounts rather than exact formats; the
# person always checks the result before anything is saved.
module SmsParser
  AMOUNT = /(?:GHS|GH₵|GH¢|GHC|₵|¢)\s*(\d[\d,]*(?:\.\d{1,2})?)/i
  INCOMING = /payment received|you have received|cash in|credited|\breceived\b|deposit|credit alert|\bcr\b/i
  OUTGOING = /payment made|your payment of|payment of|payment for|cash out|\bsent\b|\bpaid\b|debited|debit alert|withdraw|purchase|transfer(?:red)? to|\bdr\b/i
  BALANCE_BEFORE = /(?:\bbal(?:ance)?(?:\s+is)?|balance\s+after)\W*\z/i
  FEE_BEFORE = /(?:fee|charges?|charged|tax|levy)(?:\s+(?:was|is|of|charged))?\W*\z/i
  PARTY_END = /(?=[.,;]\s|[.,;]?\z|\s+(?:on|at|current|your|ref|reference|has|have|is|new|avail\w*|transaction|trans|via|with)\b)/i
  TXN_ID = /(?:financial\s+transaction\s+id|transaction\s+id|trans(?:action)?\.?\s*id|txn\s*id|ref(?:erence)?\s*(?:no|number|#))\s*[:.#]?\s*([A-Z0-9][A-Z0-9.\-]{4,})/i
  DESCRIPTION = /\b(?:desc(?:ription)?|narration|remarks?|details)\s*:?\s*(.+?)(?=\s+(?:avail\w*|bal(?:ance)?|date|amt|amount|ref\w*|acc(?:oun)?t)\b|\.(?:\s|\z)|\z)/i
  MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze

  module_function

  def parse(text, today: Date.today)
    text = text.to_s.gsub(/\s+/, ' ').strip
    direction = direction(text)
    amounts = amounts(text)
    main = amounts.find { |a| a[:role] == :amount }
    {
      direction: direction,
      amount: main && main[:value],
      fee: amounts.select { |a| a[:role] == :fee }.sum { |a| a[:value] },
      balance: balance(amounts),
      counterparty: counterparty(text, direction),
      reference: field(text, /\breference\s*:?\s*([^.]*)/i),
      description: field(text, DESCRIPTION),
      ref_id: txn_id(text),
      on: date(text, today),
      network: network(text)
    }
  end

  # :in or :out, from whichever keyword comes first; nil when neither appears.
  def direction(text)
    incoming = text =~ INCOMING
    outgoing = text =~ OUTGOING
    return nil unless incoming || outgoing
    return :in unless outgoing
    return :out unless incoming

    incoming < outgoing ? :in : :out
  end

  # Every amount with what it is, judged from the words just before it.
  def amounts(text)
    text.to_enum(:scan, AMOUNT).map do
      match = Regexp.last_match
      before = text[[match.begin(0) - 30, 0].max...match.begin(0)]
      role = if before.match?(BALANCE_BEFORE) then :balance
             elsif before.match?(FEE_BEFORE) then :fee
             else :amount
             end
      { value: Money.parse(match[1]), role: role, before: before.downcase }
    end
  end

  # The available balance when there is one, else the first balance.
  def balance(amounts)
    balances = amounts.select { |a| a[:role] == :balance }
    (balances.find { |a| a[:before].include?('avail') } || balances.first)&.dig(:value)
  end

  def counterparty(text, direction)
    word = { in: 'from', out: 'to' }[direction]
    return nil unless word

    match = text.match(/\b#{word}\s+(.+?)#{PARTY_END}/i)
    name = match && match[1].strip
    name && !name.empty? && name.length <= 60 && !name.match?(AMOUNT) ? name : nil
  end

  def txn_id(text)
    (text[TXN_ID, 1] || text[/\A([A-Z0-9]{6,})\s+confirmed\b/i, 1])&.sub(/[.\-]+\z/, '')
  end

  def field(text, pattern)
    value = text[pattern, 1].to_s.strip
    value.empty? || value == '-' ? nil : value[0, 80]
  end

  # 2026-10-14, 14/10/2026, 14-10-26 or 14-Oct-2026. Ignores dates that can't
  # be right (in the future).
  def date(text, today)
    found = if (m = text.match(/\b(\d{4})-(\d{2})-(\d{2})\b/))
              safe_date(m[1].to_i, m[2].to_i, m[3].to_i)
            elsif (m = text.match(%r{\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b}))
              safe_date(full_year(m[3]), m[2].to_i, m[1].to_i)
            elsif (m = text.match(/\b(\d{1,2})[\s-]([A-Za-z]{3})[a-z]*[\s,-]+(\d{2,4})\b/))
              month = MONTHS.index(m[2].downcase)
              month && safe_date(full_year(m[3]), month + 1, m[1].to_i)
            end
    found && found <= today ? found : nil
  end

  def network(text)
    case text
    when /telecel|vodafone/i then { name: 'Telecel Cash', kind: 'momo' }
    when /airteltigo|\bat money\b|atmoney/i then { name: 'AT Money', kind: 'momo' }
    when /\bmomo\b|\bmtn\b|financial transaction id|current balance/i then { name: 'MTN MoMo', kind: 'momo' }
    when %r{\bacc(?:oun)?t\b|\ba/c\b|\bbank\b|avail(?:able)?\s+bal}i then { name: 'Bank', kind: 'bank' }
    end
  end

  def full_year(raw)
    raw.length == 2 ? 2000 + raw.to_i : raw.to_i
  end

  def safe_date(year, month, day)
    Date.new(year, month, day)
  rescue Date::Error
    nil
  end
end
