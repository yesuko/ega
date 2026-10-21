require 'bcrypt'

class User < Sequel::Model
  one_to_many :accounts, order: [:position, :id]
  one_to_many :pots, order: [:position, :id]
  one_to_many :transactions
  one_to_many :buy_items
  one_to_many :investments

  DEFAULT_ACCOUNTS = [['Bank savings', 'bank'], ['MoMo', 'momo'], ['Cash', 'cash'], ['Investments', 'investment']].freeze
  # kind, name, percent, home account (by name; nil = anywhere)
  DEFAULT_POTS = [
    ['future', 'Future Me', 20, 'Bank savings'],
    ['buy', 'Buy List', 10, 'Bank savings'],
    ['living', 'Living', 50, nil],
    ['enjoy', 'Enjoy', 20, nil]
  ].freeze

  def password=(plaintext)
    self.password_digest = BCrypt::Password.create(plaintext)
  end

  def authenticate(plaintext)
    BCrypt::Password.new(password_digest) == plaintext
  rescue BCrypt::Errors::InvalidHash
    false
  end

  def before_validation
    self.emergency_months ||= 3
    self.cooling_hours ||= 48
    super
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

  # Every user starts with the same accounts and the four pots.
  def after_create
    super
    by_name = DEFAULT_ACCOUNTS.each_with_index.to_h do |(name, kind), index|
      [name, Account.create(user_id: id, name: name, kind: kind, position: index + 1)]
    end
    DEFAULT_POTS.each_with_index do |(kind, name, percent, home), index|
      Pot.create(user_id: id, kind: kind, name: name, percent: percent, home_account_id: by_name[home]&.id, position: index + 1)
    end
  end

  def pot(kind)
    @pots_by_kind ||= pots.to_h { |p| [p.kind, p] }
    @pots_by_kind.fetch(kind)
  end

  # Accounts money can be received into, spent from or moved between.
  def cash_accounts
    accounts.reject { |a| a.investment? || a.archived? }
  end

  def investments_account
    accounts.find(&:investment?)
  end

  def account(id)
    accounts.find { |a| a.id == id.to_i }
  end

  def first_name
    name.to_s.split.first || name
  end

  def validate
    super
    errors.add(:name, 'is required') if name.to_s.strip.empty?
    errors.add(:name, 'must be 60 characters or fewer') if name.to_s.length > 60
    if email.to_s.strip.empty?
      errors.add(:email, 'is required')
    elsif !email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      errors.add(:email, "doesn't look like an email address")
    elsif self.class.exclude(id: id).where(email: email.downcase).any?
      errors.add(:email, 'already has an account')
    end
    errors.add(:payday, 'must be a day from 1 to 31') if payday && !(1..31).cover?(payday)
    errors.add(:emergency_months, 'must be from 1 to 12') unless (1..12).cover?(emergency_months.to_i)
    errors.add(:cooling_hours, 'must be from 0 to 168') unless (0..168).cover?(cooling_hours.to_i)
    errors.add(:living_target, 'must be more than zero, or left blank') if living_target && !living_target.positive?
  end
end
