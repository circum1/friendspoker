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
  attr_accessor :table, :evt
  def initialize(table, payload)
    @table = table
    @evt = {
      timestamp: Time.now,
      type: self.class.name,
      event: payload,
    }
  end

  def to_s
    "#{@evt[:type]}:#{@evt[:timestamp].strftime("%k:%M:%S")}:#{@evt[:event]}"
  end
end

class HeartbeatEvent < PokerEvent; end
class WhosNextEvent < PokerEvent; end
class GameStateEvent < PokerEvent; end

# PlayerActionEvent = Struct.new(:player, :action, :amount)
# end

# GameUpdatedEvent

# singleton? module? class methods?
module EventMgr
  def self.notify(event)
    $log.debug("EventMgr#notify(#{event})")
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
    @last_action = what
  end

  def nextRound
    @last_action = nil
    @money_in_round = 0
  end

  # serializable state that is visible at the table from a player, in a form of hash
  # cards not included
  def get_state
    attr2hash(:last_action, :money_in_round, :folded)
      .merge(@player.get_state)
  end

  # serializable state visible only for the given player (i.e., cards)
  def get_private_state
    res = {cards: cards}
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

  attr_reader :deck

  # index of player with dealing button
  attr_reader :button

  # array of PlayerInGame objects
  attr_reader :pigs

  # 0..3: preflop, flop, turn, river
  attr_reader :round

  # index of the last player who raised, the one before that can speak last time
  attr_reader :last_raiser

  # index of next player (who needs to action), deadline for the action
  attr_reader :waiting_for, :deadline

  attr_reader :community_cards

  # serializable, public state of the table (can be sent to clients)
  # cards in players' hands not included
  def get_state
    h = attr2hash(:button, :round, :last_raiser, :waiting_for, :deadline, :community_cards)
    h[:pigs] = pigs.map {|p| p.get_state}
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
  end

  def add_to_pot(amount)
    @money_in_pot += amount
  end

  def act_pig
    @pigs[@waiting_for]
  end

  def valid_actions_for_next
    res = [:fold]
    res << :raise if act_pig.player.money > 0
    if @pigs.map(&:money_in_round).max <= act_pig.money_in_round
      res << :check
    else
      res << :call
    end
  end


  def action(what, who, raise_amount = 0)
    raise InvalidActionError, "Game has finished" if finished?
    raise InvalidActionError,
      "Action from player #{who} but it's #{act_pig.player}'s turn'" if act_pig.player != who

    maxbet = @pigs.map(&:money_in_round).max
    act_pig.action(what, maxbet, raise_amount)
    @last_raiser = @waiting_for if what == :raise

    still_playing = @pigs.select { |p| p.folded == false }
    whos_next(still_playing)

    if finished?
      if still_playing.size == 1
        winners = [still_playing[0].player]
      else
        winner = nil
        hands = still_playing.map { |p| Hand.new(community_cards + p.cards) }
        winnerhand = hands.max
        winners = still_playing.select.with_index { |p, i| hands[i] == winnerhand }
      end
      $log.debug("The winner(s): #{winners}")
      amount = @money_in_pot / winners.size
      winners.each { |w| w.add_money(amount) }
      winners[0].add_money(@money_in_pot - amount * winners.size)
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
  attr_reader :id, :nickname
  attr_accessor :active
  def initialize(id, nickname)
    @id = id
    @nickname = nickname
    @active = true
  end

  def to_s
    "#{nickname}"
  end
end

# One poker table.
class Table
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
      attr2hash(:starting_money, :money, :nickname)
    end

    def to_s
      "#{nickname}(#{money})"
    end

    def inspect
      "#<PAT: @nickname: #{nickname}, @money: #{money}>"
    end
  end


  def initialize(owner)
    # TODO parameterize
    @starting_money = 1000
    @timeout = 30

    @owner = owner
    @players = [PlayerAtTable.new(owner, @starting_money, self)]
    @pending_players = []
    @current_game = nil
    @button = 0
  end

  def start_game
    @players += @pending_players
    @pending_players = []

    # TODO check if no ongoing game
    @current_game = Game.new(self, @button, @timeout)
    @button = (@button + 1) % players.size

    emit_events
  end

  def add_player(player)
    @pending_players << PlayerAtTable.new(player, @starting_money, self)
  end

  def remove_player(player)
    # TODO, may be complicated if in game
  end

  def action(what, who, raise_amount=0)
    if current_game
      # TODO check finished before and after...
      current_game.action(what, who, raise_amount)
      emit_events
    end
  end

  def emit_events
    EventMgr.notify(GameStateEvent.new(self, current_game.get_state))
    EventMgr.notify(WhosNextEvent.new(self, {
      player: current_game.act_pig.player,
      actions: current_game.valid_actions_for_next
    }))
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
