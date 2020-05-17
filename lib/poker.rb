require "logger"

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

class EventMgr
end

class PokerGame
end

class Lobby
end

# Representation of a card
# color is one of C, D, H, S
# number is 1-13 (ace is 1)
class Card
  attr_accessor :color, :number

  def initialize(color, number)
    # TODO check
    raise "Invalid card number #{number}" if !number.between?(1, 13)
    color.upcase!
    raise "Invalid card color #{color}" if !['C', 'D', 'H', 'S'].include?(color)
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

  def <=>(other)
    my = number
    my = 14 if my == 1
    their = other.number
    their == 14 if their == 1
    my <=> their
  end
end

def combination(arr, nselect)
  raise "nselect #{nselect} cannot be greater than arr.size #{arr.size}" if nselect > arr.size
  # indices
  is = (0..nselect-1).to_a
  maxind = arr.size-1

  # pos indexes is, valid between 0..nselect-1
  incrInd = proc { |pos|
    is[pos] += 1
    (pos+1..nselect-1).each { |i|
      is[i] = is[i-1] + 1
    }
    if is[-1] > maxind
      if pos == 0
        false
      else
        # overflow
        incrInd.call(pos-1)
      end
    else
      true
    end
  }

  while true do
    yield is.map { |i| arr[i] }
    res = incrInd.call(nselect-1)
    break if !res
    # break if !incrInd.call(nselect-1)
  end
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
  def initialize
  end

  def shuffle
  end

  def draw
  end
end
