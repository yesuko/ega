require 'json'

class Transaction < Sequel::Model
  many_to_one :user
  many_to_one :buy_item
  many_to_one :investment
  many_to_one :bill
  one_to_many :entries, order: :id

  KINDS = {
    'income' => 'Income', 'spend' => 'Spending', 'move' => 'Move', 'shift' => 'Pot to pot',
    'check' => 'Balance check', 'opening' => 'Starting balance', 'invest' => 'Invested',
    'growth' => 'Investment value', 'cashout' => 'Investment cashed out'
  }.freeze
  ICONS = {
    'income' => :arrow_down_left, 'spend' => :arrow_up_right, 'move' => :arrow_left_right,
    'shift' => :arrow_left_right, 'check' => :scale, 'opening' => :flag, 'invest' => :trending_up,
    'growth' => :trending_up, 'cashout' => :coins
  }.freeze

  dataset_module do
    def latest_first
      order(Sequel.desc(:occurred_on), Sequel.desc(:id))
    end
  end

  def kind_label
    KINDS.fetch(kind, kind)
  end

  def icon
    ICONS.fetch(kind, :wallet)
  end

  def snapshot_data
    snapshot ? JSON.parse(snapshot) : nil
  end

  # Investment events are undone from the investment's page, latest first.
  def investment_event?
    %w[invest growth cashout].include?(kind) && investment_id
  end

  # A spend or balance check with a single entry, not a Buy List purchase,
  # can be moved to another pot.
  def pot_changeable?
    %w[spend check].include?(kind) && buy_item_id.nil? && entries.size == 1
  end

  # Net effect on what you own: income and checks add, spending takes away,
  # moves and pot-to-pot changes net to zero.
  def net
    entries.sum(&:amount)
  end
end
