# Tests run against a fresh in-memory SQLite database; .env is never loaded,
# so real data is never touched.
ENV['RACK_ENV'] = 'test'
ENV['SESSION_SECRET'] ||= 'test-secret-' * 8

require 'minitest/autorun'
require 'sequel'
require 'bcrypt'
require 'date'
require 'securerandom'

root = File.expand_path('..', __dir__)
DB = Sequel.sqlite
Sequel.extension :migration
Sequel::Migrator.run(DB, File.join(root, 'db', 'migrate'))
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

%w[lib/money lib/sms_parser models/user models/account models/pot models/buy_item models/investment
   models/transaction models/entry lib/plan lib/ledger].each { |file| require File.join(root, file) }

# Every test runs inside a transaction that is rolled back afterwards.
module RollbackEachTest
  def run(...)
    result = nil
    DB.transaction(rollback: :always, auto_savepoint: true) { result = super }
    result
  end
end
Minitest::Test.prepend(RollbackEachTest)

class Minitest::Test
  def make_user(**attributes)
    user = User.new({ name: 'Ama Test', email: "ama-#{SecureRandom.hex(4)}@example.com" }.merge(attributes))
    user.password = 'password123'
    user.save
    User[user.id]
  end

  def account(user, name)
    user.accounts.find { |a| a.name == name }
  end

  def ledger(user, today = Date.today)
    Ledger.new(user, Plan.new(user, today: today))
  end

  def plan(user, today = Date.today)
    Plan.new(User[user.id], today: today)
  end

  def cedis(amount)
    Money.parse(amount.to_s)
  end
end
