require "bundler"

ENV["RAILS_ENV"] = "test"

RSpec.configure do |config|
  config.around(:each) do |example|
    # Disconnect from database before running acceptance tests that shell out to rake
    # This prevents "database is being accessed by other users" errors
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)

    Dir.chdir("spec/dummy") do
      example.run
    end
  ensure
    # Clean up generated files after EACH test using git reset
    Dir.chdir("spec/dummy") do
      system "git add -A 2>/dev/null && git reset --hard HEAD 1>/dev/null 2>&1"
    end

    # Reconnect to database for subsequent unit tests
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
  end

  config.before(:suite) do
    Dir.chdir("spec/dummy") do
      system <<-CMD
        git init 1>/dev/null &&
        git add -A &&
        git commit --no-gpg-sign --message 'initial' 1>/dev/null
      CMD
    end
  end

  config.after(:suite) do
    # Disconnect from database BEFORE cleanup to prevent "database in use" errors
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)

    Dir.chdir("spec/dummy") do
      # Clean up files FIRST (using git reset), THEN handle database
      system <<-CMD
        echo &&
        git add -A 2>/dev/null &&
        git reset --hard HEAD 1>/dev/null &&
        rm -rf .git/ 1>/dev/null &&
        rake db:environment:set db:drop db:create 2>/dev/null
      CMD
    end
  end
end
