#!/usr/bin/env ruby

require_relative "poker"
require "test/unit"

class TestPoker < Test::Unit::TestCase

  def test_card_fromstring
    tcs = [
      ["C10", :C, 10],
      ["DA", :D, 1],
      ["HJ", :H, 11],
      ["S2", :S, 2],
    ]
    tcs.each { |s, col, num|
      c = Card.fromString(s)
      assert_equal(col, c.color)
      assert_equal(num, c.number)
    }
  end

  def test_card_order
    tcs = [
      ["C10", "H10", 0],
      ["CA", "CK", 1],
      ["C10", "CJ", -1],
    ]
    tcs.each { |s1, s2, res|
      c1 = Card.fromString(s1)
      c2 = Card.fromString(s2)
      assert_equal(c1 <=> c2, res)
    }
  end

  def test_hand_rank
    tcs = [
      [["C3", "CQ", "C7", "CK", "HA"], :high_card, [14, 13, 12, 7, 3]],
      [["C3", "C7", "C7", "CK", "HA"], :pair, [7, 14, 13, 3]],
      [["C3", "C7", "C7", "CK", "H3"], :two_pairs, [7, 3, 13]],
      [["C3", "C7", "C7", "CK", "H7"], :three_of_a_kind, [7, 13, 3]],
      [["C7", "C7", "C7", "CK", "H7"], :four_of_a_kind, [7, 13]],
      [["C3", "C7", "C7", "C3", "H3"], :full_house, [3, 7]],
      [["C3", "C10", "C7", "CK", "CA"], :flush, [14, 13, 10, 7, 3]],
      [["D6", "C2", "C3", "C4", "H5"], :straight, [6, 5, 4, 3, 2]],
      [["DQ", "CK", "CA", "C10", "HJ"], :straight, [14, 13, 12, 11, 10]],
      [["DA", "C2", "C3", "C4", "H5"], :straight, [5, 4, 3, 2, 1]],
      [["C6", "C2", "C3", "C4", "C5"], :straight_flush, [6, 5, 4, 3, 2]],
      [["CQ", "CK", "CA", "C10", "CJ"], :royal_flush, [14, 13, 12, 11, 10]],
    ]
    tcs.each { | h, r, o |
      h = Hand.new(h)
      # $log.debug("#{h}")
      assert_equal(Hand::Rank.new(ranking: r, order: o), h.rank)
    }
  end

  def test_hand_rank_compare
    tcs = [
      [["C3", "CQ", "C7", "CK", "HA"], ["C3", "CQ", "C9", "CK", "HA"], -1],
      [["C3", "CQ", "C7", "CK", "HA"], ["C3", "CQ", "C3", "CK", "HA"], -1],
      [["C3", "CQ", "C7", "CK", "CA"], ["CQ", "CQ", "CQ", "CK", "HA"], 1],
      [["C3", "CQ", "C7", "CK", "CA"], ["CQ", "CQ", "CQ", "C3", "H3"], -1],
      [["C7", "CQ", "C7", "CQ", "HA"], ["C7", "CQ", "C7", "CQ", "HK"], 1],
      [["C7", "CQ", "C7", "CQ", "HA"], ["C9", "CJ", "C9", "CJ", "HA"], 1],
      [["C7", "CQ", "C7", "CQ", "H7"], ["C8", "CK", "C8", "CK", "H8"], -1],
    ]
    tcs.each { | h1, h2, r |
      # h = Hand.new(h)
      # $log.debug("#{h}")
      assert_equal(r, Hand.new(h1) <=> Hand.new(h2),  "Compared #{h1} <=> #{h2}")
    }
  end

  def test_combination
    tcs = [
      [ [1,2,3,4,5], 3,
        [[1,2,3],[1,2,4],[1,2,5],
        [1,3,4],[1,3,5],[1,4,5],[2,3,4],[2,3,5],[2,4,5],[3,4,5]]
      ],
    ]
    tcs.each { | arr, sel, exp |
      res = []
      combination(arr,sel) {|c| res << c }
      $log.debug("exp: #{exp}")
      assert_equal(exp, res)
    }
  end

  def test_hand_7_cards
    tcs = [
      [["C6", "H4", "D3", "C2", "C7", "CK", "HA"], :high_card, [14, 13, 7, 6, 4]],
      [["C6", "H4", "D3", "C2", "C2", "CK", "HA"], :pair, [2, 14, 13, 6]],
      [["C6", "C4", "D3", "C2", "C7", "CK", "HA"], :flush, [13, 7, 6, 4, 2]],
    ]
    tcs.each { | h, r, o |
      h = Hand.new(h)
      # $log.debug("#{h}")
      assert_equal(Hand::Rank.new(ranking: r, order: o), h.rank)
    }
  end


end