class Pot < Sequel::Model
  many_to_one :user
  many_to_one :home_account, class: :Account

  ABOUT = {
    'future' => 'Savings and investments. Not for daily spending.',
    'buy' => 'Fills your Buy List, top item first.',
    'living' => 'Rent, transport, food, data and bills.',
    'enjoy' => 'Guilt-free spending. Spending it is part of the plan.'
  }.freeze
  ICONS = { 'future' => :sprout, 'buy' => :shopping_bag, 'living' => :receipt, 'enjoy' => :sparkles }.freeze

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
    errors.add(:name, 'is required') if name.to_s.strip.empty?
    errors.add(:name, 'must be 30 characters or fewer') if name.to_s.length > 30
    errors.add(:percent, 'must be a whole number from 0 to 100') unless (0..100).cover?(percent)
  end

  def about
    ABOUT[kind]
  end

  def icon
    ICONS[kind]
  end
end
