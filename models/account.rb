class Account < Sequel::Model
  many_to_one :user

  KINDS = { 'bank' => 'Bank', 'momo' => 'MoMo', 'cash' => 'Cash' }.freeze
  ICONS = { 'bank' => :landmark, 'momo' => :smartphone, 'cash' => :banknote, 'investment' => :trending_up }.freeze

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
    errors.add(:kind, 'is not one of bank, MoMo or cash') unless KINDS.key?(kind) || kind == 'investment'
    if name && self.class.exclude(id: id).where(user_id: user_id, Sequel.function(:lower, :name) => name.strip.downcase).any?
      errors.add(:name, 'is already used by another account')
    end
  end

  def investment?
    kind == 'investment'
  end

  def cash?
    kind == 'cash'
  end

  def archived?
    !archived_at.nil?
  end

  def icon
    ICONS.fetch(kind, :wallet)
  end
end
