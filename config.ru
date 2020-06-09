require File.join(File.dirname(__FILE__), 'application')

# set :run, false
# set :environment, :production

# FileUtils.mkdir_p 'log' unless File.exists?('log')
# log = File.new("log/sinatra.log", "a+")
# $stdout.reopen(log)
# $stderr.reopen(log)

# this does not redirect
# use Rack::Static, :urls => {"/" => 'index.html'}, :root => 'public'
use Rack::Static, :urls => ["/frontend/react-poker/build"]

map('/api') {run PokerApi}

class RedirectIndexApp
  def self.call(env)
    [ 302, {'Location' =>"/frontend/react-poker/build/index.html"}, [] ]
  end
end
run RedirectIndexApp
