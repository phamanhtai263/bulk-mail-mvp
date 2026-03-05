namespace :db do
  desc "Load solid_queue/cache/cable schemas only if their tables do not yet exist"
  task load_secondary_schemas: :environment do
    unless ActiveRecord::Base.connection.table_exists?("solid_queue_recurring_tasks")
      puts "Loading queue schema..."
      load Rails.root.join("db/queue_schema.rb")
    end

    unless ActiveRecord::Base.connection.table_exists?("solid_cache_entries")
      puts "Loading cache schema..."
      load Rails.root.join("db/cache_schema.rb")
    end

    unless ActiveRecord::Base.connection.table_exists?("solid_cable_messages")
      puts "Loading cable schema..."
      load Rails.root.join("db/cable_schema.rb")
    end
  end
end
