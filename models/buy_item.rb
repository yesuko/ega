class BuyItem < Sequel::Model
  many_to_one :user

  dataset_module do
    def ordered
      order(:position, :id)
    end

    def listed
      where(status: 'listed').ordered
    end

    def cooling
      where(status: 'cooling').order(:cooling_until, :id)
    end

    def done
      where(status: %w[bought dropped]).order(Sequel.desc(:updated_at))
    end
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
    errors.add(:name, 'must be 60 characters or fewer') if name.to_s.length > 60
    errors.add(:price, 'must be an amount like 250 or 250.00') unless price&.positive?
    errors.add(:note, 'must be 200 characters or fewer') if note.to_s.length > 200
  end

  def cooled?(now = Time.now)
    status == 'cooling' && cooling_until <= now
  end

  def snapshot
    { 'status' => status, 'bought_on' => bought_on&.iso8601, 'paid' => paid, 'position' => position }
  end

  def restore(data)
    update(status: data['status'], bought_on: data['bought_on'] && Date.parse(data['bought_on']), paid: data['paid'], position: data['position'])
  end
end
