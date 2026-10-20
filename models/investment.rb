require 'bigdecimal'

class Investment < Sequel::Model
  many_to_one :user
  one_to_many :transactions, order: [Sequel.desc(:occurred_on), Sequel.desc(:id)]

  KINDS = {
    'tbill' => 'Treasury bill', 'bond' => 'Government bond', 'fund' => 'Mutual fund / unit trust',
    'stock' => 'GSE shares', 'pension' => 'Tier 3 pension', 'deposit' => 'Fixed deposit', 'other' => 'Other'
  }.freeze
  # Kinds that pay a set rate to a maturity date, so the payout can be estimated.
  FIXED_RATE = %w[tbill bond deposit].freeze

  dataset_module do
    def active
      where(status: 'active').order(Sequel.asc(:matures_on, nulls: :last), :id)
    end

    def closed
      where(status: 'closed').order(Sequel.desc(:closed_on), Sequel.desc(:id))
    end
  end

  def before_create
    self.created_at ||= Time.now
    self.updated_at ||= Time.now
    super
  end

  def before_update
    self.updated_at = Time.now
    super
  end

  def validate
    super
    errors.add(:kind, 'must be chosen') unless KINDS.key?(kind)
    errors.add(:name, 'is required') if name.to_s.strip.empty?
    errors.add(:name, 'must be 60 characters or fewer') if name.to_s.length > 60
    errors.add(:provider, 'must be 60 characters or fewer') if provider.to_s.length > 60
    errors.add(:started_on, 'is required') unless started_on
    errors.add(:matures_on, 'must be after the start date') if matures_on && started_on && matures_on <= started_on
    errors.add(:rate, 'must be from 0 to 200') if rate && !(0..200).cover?(rate)
  end

  def kind_label
    KINDS.fetch(kind, kind)
  end

  def active?
    status == 'active'
  end

  def gain
    value - principal
  end

  def days_to_maturity(today = Date.today)
    matures_on && (matures_on - today).to_i
  end

  # A rough figure for fixed-rate holdings: simple interest on what is in now.
  # Ghana T-bills count a 364-day year.
  def expected_at_maturity
    return nil unless FIXED_RATE.include?(kind) && rate && matures_on

    days = (matures_on - started_on).to_i
    year = kind == 'tbill' ? 364 : 365
    principal + (principal * rate * days / (100 * year)).round.to_i
  end

  def snapshot
    { 'principal' => principal, 'value' => value, 'status' => status, 'closed_on' => closed_on&.iso8601 }
  end

  def restore(data)
    update(principal: data['principal'], value: data['value'], status: data['status'],
           closed_on: data['closed_on'] && Date.parse(data['closed_on']))
  end
end
