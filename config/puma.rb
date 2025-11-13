# frozen_string_literal: true

# Puma configuration file

# The directory to operate in, defaults to the current directory
directory ENV.fetch('APP_ROOT', Dir.pwd)

# Set the environment
environment ENV.fetch('RAILS_ENV', 'development')

# Daemonize the server into the background (optional)
# daemonize ENV.fetch('PUMA_DAEMONIZE', 'false') == 'true'

# Store the pid in a file
pidfile ENV.fetch('PIDFILE', 'tmp/pids/puma.pid')

# Use "path" as the file to store the server info state
state_path ENV.fetch('PUMA_STATE', 'tmp/pids/puma.state')

# Redirect STDOUT and STDERR to files
if ENV.fetch('RAILS_ENV', 'development') == 'production'
  stdout_redirect(
    ENV.fetch('PUMA_STDOUT_LOG', 'log/puma.stdout.log'),
    ENV.fetch('PUMA_STDERR_LOG', 'log/puma.stderr.log'),
    true
  )
end

# Configure "min" to be the minimum number of threads to use to answer
# requests and "max" the maximum
threads_count = ENV.fetch('RAILS_MAX_THREADS', 5).to_i
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests
port ENV.fetch('PORT', 3000)

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments
worker_timeout 3600 if ENV.fetch('RAILS_ENV', 'development') == 'development'

# Specifies the number of `workers` to boot in clustered mode
# Workers are forked web server processes. If using threads and workers together
# the concurrency of the application would be max `threads` * `workers`
# Workers do not work on JRuby or Windows (both of which do not support processes)
workers ENV.fetch('WEB_CONCURRENCY', 2).to_i

# Use the `preload_app!` method when specifying a `workers` number
# This directive tells Puma to first boot the application and load code
# before forking the application. This takes advantage of Copy On Write
# process behavior so workers use less memory
preload_app!

# Allow puma to be restarted by `bin/rails restart` command
plugin :tmp_restart

# Bind to UNIX socket for better performance (production)
if ENV.fetch('RAILS_ENV', 'development') == 'production'
  bind "unix://#{ENV.fetch('APP_ROOT', Dir.pwd)}/tmp/sockets/puma.sock"
else
  # Development mode - bind to port
  port ENV.fetch('PORT', 3000)
end

# === Cluster mode ===
on_worker_boot do
  # Worker specific setup for Rails
  # This is required for ActiveRecord to work correctly in clustered mode
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  
  # If using Redis/Sidekiq, reconnect
  if defined?(Redis)
    Redis.current.disconnect!
    Redis.current = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
  end
  
  # Reconnect to any other external services
  if defined?(Sidekiq)
    Sidekiq.configure_client do |config|
      config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
    end
  end
end

before_fork do
  # Close database connections before forking
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
  
  # Close Redis connections
  Redis.current.disconnect! if defined?(Redis)
end

# === Health check endpoint ===
# This allows load balancers to verify if the server is running
lowlevel_error_handler do |e, env|
  if env['PATH_INFO'] == '/health'
    [200, {}, ["OK\n"]]
  else
    [500, {}, ["Internal Server Error\n"]]
  end
end

# === Performance tuning ===

# Increase backlog for high traffic (removed - not supported in Puma 6.6.1)
# backlog ENV.fetch('PUMA_BACKLOG', 1024).to_i

# Set the timeout for client connections
# Default is 60 seconds, increase for slow clients
persistent_timeout ENV.fetch('PUMA_PERSISTENT_TIMEOUT', 60).to_i

# First request timeout
first_data_timeout ENV.fetch('PUMA_FIRST_DATA_TIMEOUT', 30).to_i

# === Logging ===
if ENV.fetch('RAILS_ENV', 'development') == 'development'
  # More verbose logging in development
  # debug
end

# === SSL (optional) ===
# Uncomment for SSL support (not recommended, use Nginx instead)
# ssl_bind ENV.fetch('PUMA_SSL_BIND', '0.0.0.0'), ENV.fetch('PUMA_SSL_PORT', '9292'),
#   key: ENV.fetch('PUMA_SSL_KEY'),
#   cert: ENV.fetch('PUMA_SSL_CERT')

# === Monitoring (optional) ===
# Activate the control app for remote management
# activate_control_app 'tcp://127.0.0.1:9293', { auth_token: ENV.fetch('PUMA_CONTROL_TOKEN') }

# === Shutdown ===
on_booted do
  Rails.logger.info "Puma started. Environment: #{ENV.fetch('RAILS_ENV', 'development')}"
  Rails.logger.info "Workers: #{ENV.fetch('WEB_CONCURRENCY', 2)}"
  Rails.logger.info "Threads: #{threads_count}"
end

on_restart do
  Rails.logger.info 'Puma restarting...'
end

on_worker_shutdown do
  Rails.logger.info 'Worker shutting down...'
end

