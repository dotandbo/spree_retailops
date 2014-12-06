require 'bundler'

APP_RAKEFILE = File.expand_path("../spec/dummy/Rakefile", __FILE__)
load 'rails/tasks/engine.rake'

RSpec::Core::RakeTask.new

Bundler::GemHelper.install_tasks

Dir[File.join(File.dirname(__FILE__), 'tasks/**/*.rake')].each {|f| load f }

require 'rspec/core'
require 'rspec/core/rake_task'
require 'spree/testing_support/extension_rake'

desc "Run all specs in spec directory (excluding plugin specs)"
RSpec::Core::RakeTask.new(:spec => 'app:db:test:prepare')

task :default => :spec

desc "Setup test database - drops, loads schema, migrates and seeds the test db"
task :setup => [:environment] do
  Rails.env = ENV['RAILS_ENV'] = 'test'
  Rake::Task['db:drop'].invoke
  Rake::Task['db:create'].invoke
  #result = capture_stdout { Rake::Task['db:schema:load'].invoke }
  #File.open(File.join(ENV['CC_BUILD_ARTIFACTS'] || 'log', 'schema-load.log'), 'w') { |f| f.write(result) }
  #Rake::Task['db:seed:load'].invoke
  ActiveRecord::Base.establish_connection
  Rake::Task['db:migrate'].invoke
end

=begin
task :default do
  if Dir["spec/dummy"].empty?
    Rake::Task[:test_app].invoke
    Dir.chdir("../../")
  end
  Rake::Task[:spec].invoke
end

desc 'Generates a dummy app for testing'
task :test_app do
  ENV['LIB_NAME'] = 'spree_retailops'
  Rake::Task['extension:test_app'].invoke
end
=end
