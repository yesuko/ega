#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Brings the database up to date with db/migrate.
# Usage: bundle exec ruby bin/migrate.rb

require 'dotenv'
require 'sequel'

root = File.expand_path('..', __dir__)
Dotenv.overload(File.expand_path('.env', root))
Dir.chdir(root)

Sequel.extension :migration
db = Sequel.connect(ENV.fetch('DATABASE_URL'))
Sequel::Migrator.run(db, File.join(root, 'db', 'migrate'))
puts "Database is up to date (#{db.tables.size} tables)."
