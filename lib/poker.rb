require "eventmachine"
require "json"
require "logger"

class InvalidActionError < StandardError
end

module JsonHelper
  def attr2hash(*names)
    Hash[names.map { |n| [n.to_sym, self.send(n)] }]
  end
end

class MyLog
  def self.log
    if @logger.nil?
      @logger = Logger.new STDOUT
      @logger.level = Logger::DEBUG
      @logger.datetime_format = "%Y-%m-%d %H:%M:%S "
    end
    @logger
  end
end

$log = MyLog.log

class PokerEvent
  include JsonHelper

  attr_accessor :channel, :evt, :id
  def initialize(channel, payload)
    @channel = channel
    @evt = {
      timestamp: Time.now,
      type: self.class.name,
      event: payload,
    }
  end

  def to_s
    "#{@evt[:type]}:#{@channel}:#{@evt[:timestamp].strftime("%k:%M:%S")}:#{@evt[:event]}"
  end

  def to_json(opts)
    JSON.generate(attr2hash(:channel, :id, :evt), opts)
  end
end

class TickEvent < PokerEvent; end
class WhosNextEvent < PokerEvent; end
class GameStateEvent < PokerEvent; end
class PlayerCardsEvent < PokerEvent; end
class MessageEvent < PokerEvent; end

module EventMgr
  @@next_id = 1
  @@ticker_runs = false
  # list of {channel: c, conn_id: conn_id, block: block} hashes
  @@subscribers = []

  def self.launchTicker
    @@ticker_runs = true
    $log.debug("Starting ticker timer");
    timer = EventMachine::PeriodicTimer.new(30) do
      event = TickEvent.new("", {})
      event.id = @@next_id
      @@next_id += 1
      @@subscribers.each { |s|
        s[:block].call(event)
      }
    end
  end

  def self.close_connection(conn_id)
    found = false
    $log.debug("close_connection with id #{conn_id}")

    @@subscribers.select { |s| s[:conn_id] == conn_id }.each do |s|
      # will be called multiple times (because of more than one channel), but that's not a problem
      s[:block].call(nil)
      found = true
    end
    found
  end

  # channel is a list of arbitrary identifiers -- using table names & user names
  # id is to identify the subscription in close_connection
  def self.subscribe(channel, conn_id, &block)
    launchTicker if !@@ticker_runs

    channel = [channel] if !channel.respond_to?(:each)
    objs = []
    channel.each { |c|
      obj = {channel: c, conn_id: conn_id, block: block}
      @@subscribers << obj
      objs << obj
    }
    $log.debug("Eventmgr.subscribe() channels: #{channel}, conn_id: #{conn_id}")

    # Heuristic: here we re-send the events for the given table, as the client cannot
    # do that without race condition (the /resend-events may be processed before this
    # subscription is done asynchronously by EventMachine)
    t = channel.map{ |c| /^table-([^:]+)/.match(c)&.[](1) }.compact[0]
    Table.get_by_name(t)&.emit_events if t

    return proc {
      objs.each { |o| unsubscribe(o) }
    }
  end

  def self.unsubscribe(obj)
    if @@subscribers.delete(obj)
      $log.debug("Subscriber from channel #{obj[:channel]} with id #{obj[:conn_id]} deleted")
    else
      # $log.debug("Subscriber on channel #{obj[:channel]} could not be deleted")
    end
  end

  def self.notify(event)
    event.id = @@next_id
    @@next_id += 1
    $log.debug("EventMgr#notify(#{event})")

    @@subscribers.select { |s| s[:channel] == event.channel }.map { |s|
      $log.debug("EventMgr#notify() sending on channel #{s[:channel]} to subscriber with id #{s[:conn_id]}")
      s[:block].call(event)
    }
  end

  # Checks for user-private channel names (with pattern "player-<name>[:<suffix>]")
  # Returns username or false
  def self.needs_auth?(channels)
    channels = [channels] if !channels.respond_to?(:each)
    p = channels.map{ |c| /^player-([^:]+):/.match(c)&.[](1) }.compact.uniq
    raise InvalidActionError, "Cannot auth to more than one 'player-*' channels" if p.size > 1
    return false if p.size == 0
    return p[0]
  end

end

class Lobby
end

class PlayerInGame
  include JsonHelper

  attr_reader :player, :last_action, :money_in_round, :cards, :folded

  # player is Table::PlayerAtTable object
  def initialize(player, game, cards, blind=0)
    @player = player
    @game = game
    nextRound
    # TODO check money
    add_to_pot(blind)
    @cards = cards
    @folded = false
  end

  def add_to_pot(amount)
    @player.subtract_money(amount)
    @game.add_to_pot(amount)
    @money_in_round += amount
  end

  # :bet should be translated to :raise by caller
  def action(what, max_bet, raise_amount=0)
    $log.debug("PIG#action(#{what}, #{max_bet}, #{raise_amount})")
    raise InvalidActionError, "player #{player} already folded" if @folded
    # for call
    amount = max_bet - @money_in_round
    case what
    when :check
      raise InvalidActionError, "Invalid check, need to call #{amount} bucks" if amount > 0
    when :call, :raise
      amount += raise_amount if what == :raise
      # TODO check if we have enough money
      add_to_pot(amount)
    when :fold
      @folded = true
    else
      raise InvalidActionError, "Unknown action #{:what}"
    end
  end

  def nextRound
    @money_in_round = 0
  end

  # serializable state that is visible at the table from a player, in a form of hash
  # cards not included
  def get_state
    @player.get_state.merge(attr2hash(:last_action, :money_in_round, :folded))
  end

  # serializable state visible only for the given player (i.e., cards)
  def get_private_state
    res = {player: player.name, cards: cards}
    res[:rank] = Hand.new(cards + @game.community_cards).rank.ranking if @game.round > 0
    res
  end

  # cards not included
  def to_json
    JSON.generate(get_state)
  end

end


# A single (ongoing) game at a table
class Game
  include JsonHelper

  VALID_ACTIONS = [:check, :call, :bet, :raise, :fold]

  attr_reader :deck

  # index of player with dealing button
  attr_reader :button

  attr_reader :money_in_pot

  # array of PlayerInGame objects
  attr_reader :pigs

  # 0..3: preflop, flop, turn, river
  attr_reader :round

  # index of the last player who raised, the one before that can speak last time
  attr_reader :last_raiser

  # index of next player (who needs to action), deadline for the action
  attr_reader :waiting_for, :deadline

  attr_reader :community_cards

  # array of names (ids) of the winner(s)
  attr_reader :winners

  # serializable, public state of the table (can be sent to clients)
  # cards in players' hands not included
  def get_state
    h = attr2hash(:community_cards, :money_in_pot, :button, :round, :last_raiser, :waiting_for, :deadline)
    h[:pigs] = pigs.map {|p| p.get_state}
    h[:winners] = @winners
    h[:finished] = @finished
    return h
  end

  # button is index in the table.players array
  # timeout is the number of seconds allowed for action
  def initialize(table, button, timeout)
    @table = table
    @button = button
    @timeout = timeout
    @deck = Deck.new
    @money_in_pot = 0
    @pigs = @table.players.map.with_index { |p, ind|
      # TODO parameterize blind
      blind = case ind
        when (button + 1) % @table.players.size then 10
        when (button + 2) % @table.players.size then 20
        else 0
        end
      PlayerInGame.new(p, self, @deck.draw2, blind)
    }
    @round = 0
    @waiting_for = (button + 3) % @pigs.size
    @deadline = Time.now + @timeout
    # the player after big blind, even if she folds...
    @last_raiser = @waiting_for
    @community_cards = []
    @finished = false
    @winners = []
  end

  def add_to_pot(amount)
    @money_in_pot += amount
  end

  def act_pig
    @pigs[@waiting_for]
  end

  def get_next_actions
    res = {
      player: act_pig.player,
      actions: [:fold],
      call_amount: nil
    }
    maxbet = @pigs.map(&:money_in_round).max
    if maxbet <= act_pig.money_in_round
      res[:actions] << :check
    else
      res[:actions] << :call
      res[:call_amount] = maxbet - act_pig.money_in_round
    end
    res[:actions] << (maxbet == 0 ? :bet : :raise) if act_pig.player.money > 0
    return res
  end

  def action(what, who, raise_amount = 0)
    raise InvalidActionError, "Game has finished" if finished?
    raise InvalidActionError,
      "Action from player #{who} but it's #{act_pig.player}'s turn'" if act_pig.player != who

    what = :raise if what == :bet

    maxbet = @pigs.map(&:money_in_round).max
    act_pig.action(what, maxbet, raise_amount)
    @last_raiser = @waiting_for if [:raise, :bet].include?(what)

    still_playing = @pigs.select { |p| p.folded == false }
    whos_next(still_playing)

    if finished?
      if still_playing.size == 1
        wins = [still_playing[0].player]
      else
        hands = still_playing.map { |p| Hand.new(community_cards + p.cards) }
        winnerhand = hands.max
        wins = still_playing.select.with_index { |p, i| hands[i] == winnerhand }.map(&:player)
      end
      $log.debug("The winner(s): #{wins}")
      amount = @money_in_pot / wins.size
      wins.each { |w| w.add_money(amount) }
      wins[0].add_money(@money_in_pot - amount * wins.size)
      @winners = wins.map(&:name)
    end
  end

  def whos_next(still_playing)
    raise "Internal error" if still_playing.size == 0
    if still_playing.size == 1
      @finished = true
      return
    end

    loop {
      @waiting_for = (@waiting_for + 1) % @pigs.size
      break if @waiting_for == @last_raiser # end of round
      break if !act_pig.folded
      # TODO check for all-in
    }

    if @waiting_for == @last_raiser
      @round += 1
      case @round
      when 1
        deck.draw
        3.times { @community_cards << deck.draw }
      when 2, 3
        deck.draw
        @community_cards << deck.draw
      else
        @finished = true
        return
      end
      @pigs.each(&:nextRound)
      @waiting_for = (@button + 1) % @pigs.size
      @last_raiser = @waiting_for
    end
    @deadline = Time.now + @timeout
  end

  def finished?
    @finished
  end

end

class Player
  @@players = {}

  attr_reader :name
  attr_accessor :active

  def initialize(name, password=nil)
    $log.debug("Player.new(#{name}, ...)")
    @name, @password = name, password
    @active = true
    @@players[name] = self
  end

  def to_s
    "#{name}"
  end

  def auth(password)
    password == @password
  end

  def self.get_by_name(name)
    p = @@players[name]
  end

  def self.players
    @@players
  end

end

#
# Table
#

# One poker table.
class Table
  @@tables = {}

  attr_reader :name
  # creator of the table, can start the game
  attr_reader :owner

  # array of players, order is important
  # array of PlayerAtTable
  attr_reader :players

  # players want to join, but waiting until the ongoing game is finished
  attr_reader :pending_players

  # if nil, game not started
  attr_reader :current_game

  # PlayerAtTable = Struct.new(:player, :money, :starting_money)
  # attr_reader :pats

  attr_accessor :starting_money, :timeout

  class PlayerAtTable < SimpleDelegator
    include JsonHelper

    attr_reader :starting_money, :money, :table
    def initialize(player, starting_money, table)
      super(player)
      @starting_money = starting_money
      @money = starting_money
      @table = table
    end

    # at bet
    def subtract_money(amount)
      # TODO check <0
      @money -= amount
    end

    def add_money(amount)
      @money += amount
    end

    def ==(other)
      self.id == other.id
    end

    def get_state
      attr2hash(:name, :starting_money, :money)
    end

    def to_s
      "#{name}(#{money})"
    end

    def inspect
      "#<PAT: @name: #{name}, @money: #{money}>"
    end
  end


  def initialize(name, owner)
    @name = name

    # TODO parameterize
    @starting_money = 1000
    @timeout = 30

    @players = [PlayerAtTable.new(owner, @starting_money, self)]
    @owner = @players[0]

    class << @players
      def by_name(name)
        self.find { |p| p.name == name }
      end
    end

    @pending_players = []
    @current_game = nil
    @button = 0

    @@tables[name] = self
  end

  def start_game
    @players.concat(@pending_players)
    @pending_players = []

    raise InvalidActionError, "Not enough players" if @players.size < 2
    raise InvalidActionError, "A game is ongoing" if @current_game && !@current_game.finished?

    @current_game = Game.new(self, @button, @timeout)
    @button = (@button + 1) % players.size
    emit_events
  end

  def add_player(player)
    # TODO what about pending_players?
    if @players.by_name(player.name)
      $log.debug("Table#add_player(#{player.name}): already added")
      return @players.by_name(player.name)
    end
    pat = PlayerAtTable.new(player, @starting_money, self)
    if !@current_game || @current.game.finished?
      @players << pat
    else
      @pending_players << pat
    end
    return pat
  end

  def remove_player(player)
    # TODO, may be complicated if in game
  end

  # what: Symbol
  # who: PlayerAtTable
  # raise_amount: Integer
  def action(what, who, raise_amount=nil)
    raise_amount = 0 if !raise_amount
    if current_game
      # TODO check finished before and after...
      current_game.action(what, who, raise_amount)
      emit_events
    end
  end

  def emit_events
    return if !current_game
    table_ch = "table-#{name}"
    EventMgr.notify(GameStateEvent.new(table_ch, current_game.get_state))
    # TODO csak a sajat eventet kell megkapni
    EventMgr.notify(WhosNextEvent.new(table_ch, current_game.get_next_actions))
    current_game.pigs.each { |pig|
      ch = current_game.finished? ? table_ch : "player-#{pig.player.name}:#{name}"
      EventMgr.notify(PlayerCardsEvent.new(ch, pig.get_private_state))
    }
  end

  def self.get_by_name(name)
    @@tables[name]
  end

  def self.get_table_names
    ['dummy'] + @@tables.keys
  end

end

# Representation of a card
# color is one of C, D, H, S
# number is 1-13 (ace is 1)
class Card
  attr_accessor :color, :number

  def initialize(color, number)
    # TODO check
    raise "Invalid card number #{number}" if !number.between?(1, 13)
    color = color.upcase.to_sym if !color.is_a?(Symbol)
    raise "Invalid card color #{color}" if ![:C, :D, :H, :S].include?(color)
    # "C"lub, "D"iamond, "H"eart, "S"pade
    @color = color
    # 1-13 -- Ace is 1
    @number = number
  end

  # Create from string representation
  # number is 2-10 or J, Q, K, A
  # Args:
  #   s string representation, like "C10" or "SD"
  def self.fromString(s)
    raise "Invalid card name '#{s}'" if s !~ /^(.)(.{1,2})$/
    col, num = $~.captures
    num.upcase!
    num = case num
            when 'J' then 11
            when 'Q' then 12
            when 'K' then 13
            when 'A' then 1
            else
                num
            end.to_i
    Card.new(col, num)
  end

  def to_s
    n = case number
      when 11  then 'J'
      when 12 then 'Q'
      when 13 then 'K'
      when 1 then 'A'
      else
          number
      end
    "#{color}#{n}"
  end

  def inspect
    to_s
  end

  def <=>(other)
    my = number
    my = 14 if my == 1
    their = other.number
    their == 14 if their == 1
    my <=> their
  end
end

# can be deleted -- array has combination method :(
def combination(arr, nselect)
  raise "nselect #{nselect} cannot be greater than arr.size #{arr.size}" if nselect > arr.size
  # indices
  is = (0..nselect-1).to_a
  maxind = arr.size-1

  # pos indexes is, valid between 0..nselect-1
  incrInd = proc { |pos|
    is[pos] += 1
    (pos+1..nselect-1).each { |i| is[i] = is[i-1] + 1 }
    next true if is[-1] <= maxind
    # we're done
    next false if pos == 0
    # overflow, increment the position before this one
    incrInd.call(pos-1)
  }

  loop {
    yield is.map { |i| arr[i] }
    break if !incrInd.call(nselect-1)
  }
end

# A >=5-cards hand, mostly for ranking purposes
class Hand
  include Comparable
  # cards is the best 5 card, orig_cards is the original hand
  attr_reader :cards, :rank, :orig_cards

  def initialize(*cards)
    @orig_cards = cards.flatten
    @orig_cards.map! { |c| c.is_a?(String) ? Card.fromString(c) : c }
    raise "#{@orig_cards} is not a valid poker hand" if @orig_cards.size < 5

    @rank = Rank.new(ranking: :high_card, order: [0])
    combination(orig_cards, 5) { |c|
      r = Rank.new(c)
      if r > @rank
        @rank = r
        @cards = c
      end
    }
    raise "Internal error" if !@cards.is_a?(Array) && @cards.size != 5
  end

  def <=>(other)
    @rank <=> other.rank
  end

  def to_s
    "(#{cards.map(&:to_s).join(" ")})[#{rank}]"
  end

  Rankings = {
    high_card: 1,
    pair: 2,
    two_pairs: 3,
    three_of_a_kind: 4,
    straight: 5,
    flush: 6,
    full_house: 7,
    four_of_a_kind: 8,
    straight_flush: 9,
    royal_flush: 10,
  }

  class Rank
    include Comparable

    attr_reader :ranking, :order

    # cards must be a 5-cards array or [ranking, order]
    def initialize(cards=nil, ranking: nil, order: nil)
      if cards
        @cards = cards
        @ranking = @@num_rank_cache[numbersString]
        if @cards.map(&:color).uniq.size == 1
          @ranking = :straight_flush if @ranking == :straight
          @ranking = :royal_flush if @ranking == :straight_flush && ([1, 13] & numbers).size == 2
          @ranking = :flush if Hand::Rankings[@ranking] < Hand::Rankings[:flush]
        end

        if [:straight, :straight_flush].include?(@ranking) && ([1, 2] & numbers).size == 2
          # special case when ace is 1
          @order = [5, 4, 3, 2, 1]
        else
          nums = numbers.map { |n| n == 1 ? 14 : n }
          # keys is value of the cards, value is number of cards with that value
          uniqnums = Hash[*nums.group_by { |v| v }.flat_map { |k, v| [k, v.size] }]
          @order = uniqnums.keys.sort_by { |n| uniqnums[n] * 1024 + n }.reverse
        end
      else
        @ranking, @order = ranking, order
      end
    end

    def numbers
      @cards.map { |c| c.number }
    end

    # for rank computation
    def numbersString
      numbers.sort.map { |n| n.to_s(16) }.join("")
    end

    def <=>(other)
      res = Rankings[ranking] <=> Rankings[other.ranking]
      return res if res != 0
      # $log.debug("Rank.<=>() #{order} vs #{other.order}, result: #{order<=>other.order}")
      order <=> other.order
    end

    def to_s
      "#{ranking}(#{order})"
    end


    def self.buildRankCache
      # num_rank_cache takes into account only numbers.
      # it is a string -> rank map, where string is
      # a representation of a 5-cards hand's number values only.

      # does not check for any kind of flush.
      @@num_rank_cache = {}

      $log.debug("Rank cache fill start")

      (1..13).each { |c1|
        (c1..13).each { |c2|
          (c2..13).each { |c3|
            (c3..13).each { |c4|
              (c4..13).each { |c5|
                hand = [c1, c2, c3, c4, c5]
                srep = hand.map { |c| c.to_s(16) }.join("")
                # 5 consecutive numbers or ace-high straight
                if hand == (c1..c1 + 4).to_a || hand == [1, 10, 11, 12, 13]
                  @@num_rank_cache[srep] = :straight
                elsif [c1, c2, c3, c4].uniq.size == 1 || [c2, c3, c4, c5].uniq.size == 1
                  @@num_rank_cache[srep] = :four_of_a_kind
                elsif hand.uniq.size == 2
                  @@num_rank_cache[srep] = :full_house
                elsif [c1, c2, c3].uniq.size == 1 || [c2, c3, c4].uniq.size == 1 || [c3, c4, c5].uniq.size == 1
                  @@num_rank_cache[srep] = :three_of_a_kind
                elsif hand.uniq.size == 3
                  @@num_rank_cache[srep] = :two_pairs
                elsif hand.uniq.size == 4
                  @@num_rank_cache[srep] = :pair
                else
                  @@num_rank_cache[srep] = :high_card
                end
              }
            }
          }
        }
      }
      $log.debug("Rank cache fill finished, #{@@num_rank_cache.size} items")
    end

    $log.debug("During Rank init")
    self.buildRankCache
  end
end

class Deck
  def initialize(deck=nil)
    if deck
      @deck = deck
      return
    end
    @deck = []
    [:C, :D, :H, :S].each{ |c|
      (1..13).each { |n|
        @deck << Card.new(c, n)
      }
    }
    @deck.shuffle!
  end

  def draw
    raise "Deck::draw() when deck is empty!" if @deck.size == 0
    @deck.pop
  end

  def draw2
    raise "Deck::draw2() when deck is empty!" if @deck.size < 2
    @deck.pop(2)
  end
end
