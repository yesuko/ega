#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Creates a user (with the default accounts and pots), or resets the password
# of an existing one.
# Usage: bundle exec ruby bin/create_user.rb "<name>" <email> <password>

require 'dotenv'
require 'sequel'
require 'bcrypt'

root = File.expand_path('..', __dir__)
Dotenv.overload(File.expand_path('.env', root))
Dir.chdir(root)

name, email, password = ARGV
if name.nil? || email.nil? || password.nil?
  warn 'Usage: bundle exec ruby bin/create_user.rb "<name>" <email> <password>'
  exit 1
end
if password.length < 8
  warn 'Use a password of at least 8 characters.'
  exit 1
end

DB = Sequel.connect(ENV.fetch('DATABASE_URL'))
%w[user account pot].each { |model| require File.join(root, 'models', model) }

email = email.strip.downcase
user = User[email: email]
if user
  user.password = password
  user.save
  puts "Password reset for #{email}."
else
  User.new(name: name, email: email).tap { |u| u.password = password }.save
  puts "Created #{name} <#{email}>, with Bank savings, MoMo, Cash and the four pots."
end
