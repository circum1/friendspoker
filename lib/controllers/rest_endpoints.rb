require 'bundler/setup'
require_relative '../poker.rb'

# For now, we do not use session or authentication
# The API expects the username in the "X-Username" header

class PokerApi < Sinatra::Application
  set :server_settings, :timeout => 3600

  before do
    content_type :json
    response.headers["Access-Control-Allow-Origin"] = "*"
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
      JSON.pretty_generate(obj)
      # JSON.generate(obj)
    end

    def check_keys(obj, *keys)
      if (keys - obj.keys.map(&:to_sym)).size > 0
        fail([400, "Missing properties: #{(keys.map(&:to_s) - obj.keys.map(&:to_s)).join(", ")}"])
      end
    end

    def authenticate
      username = request.env['HTTP_X_USERNAME']
      fail([403, "Missing X-Username header"]) if !username
      name, pass = username.split(":")
      fail([403, "Missing username"]) if !name || name.size < 1
      @player = Player.get_by_name(name)
      fail([403, "Bad password"]) if @player && !@player.auth(pass)
      # implicit user creation (no need for signing in)
      @player ||= Player.new(name, pass)
      $log.debug("\"#{request.request_method} #{request.fullpath}\" - authenticated with user #{@player.name}")
    end

    # Table-related endpoints for members at that table
    def table_context
      authenticate
      @table = Table.get_by_name(params['name'])
      fail([404, "Table with name #{params['name']} not found!"]) if !@table
      # promote @player to PlayerAtTable object from Player
      @player = @table.players.by_name(@player.name)
    end
  end

  #
  # EVENTS
  #

  # Poll events for
  # request params:
  #   channel: channel to subscribe -- 'player-<name>' channel is implicit
  #   id: id for /cancel-poll endpoint
  get '/poll-events' do
    authenticate
    $log.debug("/poll-events for user #{@player.name} on #{params[:channel]}")
    check_keys(params, :channel, :id)
    channels = params[:channel].split(",")
    if (expectedName = EventMgr.needs_auth?(channels))
      fail([403, "Unauthorized channel for this user"]) if expectedName != @player.name
    end

    channels << "player-#{@player.name}"
    stream(:keep_open) do |out|
      # this code runs asynchronously
      unsub = EventMgr.subscribe(channels, "#{@player.name}:#{params[:id]}") { |evt|
        if evt
          out << "#{mk_json(evt)}"
          out << "\n{\"separator\":\"cb935688-891a-45d1-9692-0275ab14be96\"}\n"
          out.close if !params.has_key?('dontclose')
        else
          out.close
        end
      }
      out.callback {
        $log.info("Callback called for /poll-events connection")
        unsub.call()
      }
      out.errback { |e|
        $log.info("Errback called for /poll-events connection: #{e}")
        unsub.call()
      }
    end
  end

  get '/cancel-poll' do
    authenticate
    $log.debug("/cancel-poll for user #{@player.name}, id: #{params[:id]}")
    check_keys(params, :id)
    fail([404, "id #{params[:id]} not found"]) if !EventMgr.close_connection("#{@player.name}:#{params[:id]}")
    [204]
  end

  #
  # TABLES
  #

  # list tables available
  get '/tables' do
    authenticate
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

  # # trigger sending out current state of the table
  # get '/tables/:name/resend-events' do
  #   table_context
  #   @table.emit_events
  #   [204]
  # end

  post '/tables/:name/start' do
    table_context
    begin
      !@table.start_game
    rescue InvalidActionError => e
      $log.info(e)
      fail([400, e.to_s])
    end
    [204]
  end

  post '/tables/:name/action' do
    table_context
    req = JSON.load(request.body.read)
    check_keys(req, :what)
    what = req['what'].downcase.to_sym
    if [:raise, :bet].include?(what)
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

  options "*" do
    response.headers["Access-Control-Allow-Methods"] = "GET, PUT, POST, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-Auth-Token, X-Username"
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Max-Age"] = "1"
    [204]
  end

end

puts "Hello world #{RUBY_VERSION}"
