# A bill paid from Living: every month (rent, ECG), every term (school fees),
# every year or just once. A spend that carries its id and a month pays it for
# that month; for a bill that isn't monthly, the month of its pay-by date.
class Bill < Sequel::Model
  REPEATS = { 'monthly' => 'Every month', 'termly' => 'Every term', 'yearly' => 'Every year', 'once' => 'Just once' }.freeze
  # Months between pay-by dates. A school term is taken as four months
  # (January, May, September); the date can be changed when a term moves.
  MONTHS = { 'termly' => 4, 'yearly' => 12 }.freeze

  many_to_one :user
  one_to_many :payments, class: :Transaction, key: :bill_id

  dataset_module do
    def active
      where(active: true).order(:position, :id)
    end
  end

  def before_validation
    self.repeats ||= 'monthly'
    super
  end

  def before_create
    self.created_at ||= Time.now
    self.updated_at ||= Time.now
    self.position = (self.class.where(user_id: user_id).max(:position) || 0) + 1 if position.to_i.zero?
    super
  end

  def before_update
    self.updated_at = Time.now
    super
  end

  def validate
    super
    errors.add(:name, 'is required') if name.to_s.strip.empty?
    errors.add(:name, 'must be 40 characters or fewer') if name.to_s.length > 40
    errors.add(:amount, 'must be an amount like 300 or 300.00') unless amount&.positive?
    errors.add(:due_day, 'must be a day from 1 to 31, or left blank') if due_day && !(1..31).cover?(due_day)
    errors.add(:repeats, 'must be every month, every term, every year or just once') unless REPEATS.key?(repeats)
    errors.add(:pay_by, "date is needed when it isn't every month") if !monthly? && pay_by.nil?
  end

  def monthly?
    repeats == 'monthly'
  end

  def once?
    repeats == 'once'
  end

  # When it falls due in the month starting on month: its due day, or the
  # month's last day when it has none (or the month is shorter).
  def due_on(month)
    last = Date.new(month.year, month.month, -1)
    Date.new(month.year, month.month, [due_day || last.day, last.day].min)
  end

  # Pay-by dates of a bill that isn't monthly, in order: the latest one on or
  # before day (when there is one), then the ones after it.
  def dates_from(day)
    return [pay_by] if once?

    step = MONTHS.fetch(repeats)
    k = [months_after_pay_by(day).div(step), 0].max
    k -= 1 if k.positive? && (pay_by >> (k * step)) > day
    (k..).lazy.map { |n| pay_by >> (n * step) }
  end

  # The pay-by date before date, one of dates_from's; nil for a one-off.
  def date_before(date)
    step = MONTHS[repeats]
    step && pay_by >> (months_after_pay_by(date) - step)
  end

  def due_label
    return REPEATS.fetch(repeats).downcase unless monthly?

    due_day ? "due on the #{ordinal(due_day)}" : 'any time in the month'
  end

  private

  def months_after_pay_by(date)
    ((date.year * 12) + date.month) - ((pay_by.year * 12) + pay_by.month)
  end

  def ordinal(day)
    suffix = (11..13).cover?(day % 100) ? 'th' : { 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(day % 10, 'th')
    "#{day}#{suffix}"
  end
end
