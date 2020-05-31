require 'bundler/setup'
require_relative '../poker.rb'

# For now, we do not use session or authentication
# The API expects the username in the "X-Username" header

class PokerApi < Sinatra::Application
  set :server_settings, :timeout => 3600

  before do
    content_type :json
  end

  helpers do
    # response is [statuscode, body]
    def fail(response)
      $log.debug("fail: #{response}")
      content_type :text
      raise "Invalid parameter #{response.inspect}" if !response.kind_of?(Array) && response.size != 2
      halt [response[0], response[1] + "\n"]
    end

    # indirection -- for debug, we generate pretty format
    def mk_json(obj)
      # JSON.pretty_generate(obj)
      JSON.generate(obj)
    end

    def check_keys(obj, *keys)
      if (keys - obj.keys.map(&:to_sym)).size > 0
        fail([400, "Missing properties: #{(keys - obj.keys).map(&:to_s).join(", ")}"])
      end
    end

    def authenticate
      username = request.env['HTTP_X_USERNAME']
      fail([401, "Missing X-Username header"]) if !username
      @player = Player.get_by_name(username)
      @player ||= Player.new(username)
    end

    # Table-related endpoints for members at that table
    def table_context
      authenticate
      @table = Table.get_by_name(params['name'])
      # promote @player to PlayerAtTable object from Player
      @player = @table.players.by_name(@player.name)
      fail([404, "Table with name #{params['name']} not found!"]) if !@table
    end
  end

  #
  # EVENTS
  #

  # Poll events for
  # request params:
  #   channel: channel to subscribe -- 'player-<name>' channel is implicit
  get '/poll-events' do
    authenticate
    $log.debug("/poll-events on #{params[:channel]}")
    channels = params[:channel].split(",")
    fail([400, "Oh, come on..."]) if channels.any?(/^player-/)
    channels << "player-#{@player.name}"
    stream(:keep_open) do |out|
      unsub = EventMgr.subscribe(channels, 0) { |evt|
        out << "#{mk_json(evt)}\n"
        out.close if !params.has_key?('dontclose')
      }
      out.callback {
        $log.info("Callback called for /poll-events connection")
        unsub.call()
      }
      out.errback {
        $log.info("Errback called for /poll-events connection")
        unsub.call()
      }
    end
  end

  #
  # TABLES
  #

  # list tables available
  get '/tables' do
    mk_json(Table.get_table_names)
  end

  # create a new table (and be the owner)
  post '/tables/:name' do
    authenticate
    name = params['name']
    # req = JSON.load(request.body.read)
    # $log.debug("Create table payload: #{req}")
    # check_keys(req, :name)
    fail([409, "Table with name #{name} already exists!"]) if Table.get_by_name(name)
    Table.new(name, @player)
    [204]
  end

  # join table
  post '/tables/:name/join' do
    authenticate
    @table = Table.get_by_name(params['name'])
    fail([404, "Table with name #{params['name']} not found!"]) if !@table
    @table.add_player(@player)
    [204]
  end

  post '/tables/:name/start' do
    table_context
    fail([400, "Not enough players"]) if !@table.start_game
    [204]
  end

  post '/tables/:name/action' do
    table_context
    req = JSON.load(request.body.read)
    check_keys(req, :what)
    what = req['what'].downcase.to_sym
    if what == :raise
      check_keys(req, :raise_amount)
      raise_amount = req['raise_amount'].to_i
      fail([400, "Invalid raise amount '#{req['raise_amount']}'"]) if raise_amount == 0
    end
    fail([400, "Invalid action #{what}"]) if !Game::VALID_ACTIONS.include?(what)
    begin
      @table.action(what, @player, raise_amount)
    rescue InvalidActionError => e
      $log.info(e)
      fail([400, e.to_s])
    end
    [204]
  end

  get '/test' do
    msg = params['msg']
    msg ||= 'Hello world'
    channel = params['channel']
    channel ||= 'test'
    EventMgr.notify(MessageEvent.new(channel, "Msg: #{msg}"))
    halt [200, "Event with message '#{msg}' created\n"]
  end

end

puts "Hello world #{RUBY_VERSION}"
