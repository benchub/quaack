# frozen_string_literal: true

require "digest"

module Quaack
  module Driver
    # A whimsical name for each rewrite, such as "Silver Fox", since numbers
    # are easy to mix up across runs.
    #
    #   RewriteNames.name(run_id, 3)            # => "Silver Fox"
    #   RewriteNames.label(run_id, "rewrite_3") # => "Rewrite Silver Fox"
    #
    # The name is only a label. The store, the protocol, and the enclave
    # keep the rewrite's number (rewrite_3), and the driver maps the number
    # to the name wherever a person reads it. Names come only from the
    # lists here, never from anything the enclave sends.
    #
    # A name is "Adjective Noun", three syllables in all: a one-syllable
    # adjective with a two-syllable noun, or the other way round. Each list
    # gives every word's syllable count, counted by hand.
    #
    # A run's names are a shuffle of every such pair, drawn in rewrite
    # order: rewrite n's name is the nth draw. Each draw is a number from
    # SHA-256 of the run ID and the draw's position, so the names are the
    # same in every process and Ruby version, a rewrite's name doesn't
    # depend on how many rewrites the run has, and no name repeats in a
    # run. Past the last name, SIZE of them, which no real run comes near,
    # a rewrite keeps its number.
    module RewriteNames
      ADJECTIVES = {
        "blithe" => 1, "blue" => 1, "bold" => 1, "brave" => 1, "brief" => 1, "bright" => 1, "brisk" => 1,
        "bronze" => 1, "brown" => 1, "calm" => 1, "chic" => 1, "chill" => 1, "clear" => 1, "cool" => 1, "crisp" => 1,
        "dear" => 1, "deep" => 1, "deft" => 1, "droll" => 1, "dry" => 1, "faint" => 1, "fair" => 1, "fast" => 1,
        "fine" => 1, "firm" => 1, "fleet" => 1, "fond" => 1, "free" => 1, "fresh" => 1, "glad" => 1, "gold" => 1,
        "good" => 1, "grand" => 1, "great" => 1, "green" => 1, "grey" => 1, "gruff" => 1, "hale" => 1, "huge" => 1,
        "hushed" => 1, "jade" => 1, "keen" => 1, "kind" => 1, "lean" => 1, "light" => 1, "lithe" => 1, "long" => 1,
        "loud" => 1, "lush" => 1, "mild" => 1, "neat" => 1, "new" => 1, "odd" => 1, "pale" => 1, "pink" => 1,
        "plain" => 1, "plump" => 1, "plush" => 1, "posh" => 1, "prim" => 1, "prime" => 1, "proud" => 1,
        "quaint" => 1, "quick" => 1, "rare" => 1, "red" => 1, "rich" => 1, "ripe" => 1, "round" => 1, "safe" => 1,
        "sharp" => 1, "shy" => 1, "sleek" => 1, "slim" => 1, "sly" => 1, "smart" => 1, "smooth" => 1, "snug" => 1,
        "soft" => 1, "spruce" => 1, "spry" => 1, "stark" => 1, "still" => 1, "stout" => 1, "strong" => 1,
        "sweet" => 1, "swift" => 1, "tall" => 1, "tan" => 1, "taut" => 1, "teal" => 1, "trim" => 1, "true" => 1,
        "vast" => 1, "warm" => 1, "wee" => 1, "wild" => 1, "wise" => 1, "wry" => 1, "young" => 1,
        "agile" => 2, "amber" => 2, "ample" => 2, "azure" => 2, "balmy" => 2, "bashful" => 2, "bouncy" => 2,
        "breezy" => 2, "busy" => 2, "candid" => 2, "cheerful" => 2, "cheery" => 2, "chipper" => 2, "clever" => 2,
        "cosmic" => 2, "cozy" => 2, "crimson" => 2, "dainty" => 2, "dandy" => 2, "dapper" => 2, "dizzy" => 2,
        "dreamy" => 2, "dusky" => 2, "eager" => 2, "earnest" => 2, "fancy" => 2, "feisty" => 2, "fluffy" => 2,
        "frosty" => 2, "fuzzy" => 2, "gentle" => 2, "giddy" => 2, "golden" => 2, "graceful" => 2, "happy" => 2,
        "hardy" => 2, "hazy" => 2, "hearty" => 2, "helpful" => 2, "honest" => 2, "humble" => 2, "icy" => 2,
        "jaunty" => 2, "jazzy" => 2, "jolly" => 2, "joyful" => 2, "jumpy" => 2, "lanky" => 2, "lively" => 2,
        "lofty" => 2, "lucky" => 2, "mellow" => 2, "merry" => 2, "mighty" => 2, "minty" => 2, "misty" => 2,
        "modest" => 2, "nifty" => 2, "nimble" => 2, "noble" => 2, "peppy" => 2, "perky" => 2, "plucky" => 2,
        "polite" => 2, "proper" => 2, "quirky" => 2, "ready" => 2, "rosy" => 2, "rustic" => 2, "rusty" => 2,
        "sandy" => 2, "scarlet" => 2, "shiny" => 2, "silent" => 2, "silver" => 2, "simple" => 2, "sleepy" => 2,
        "snappy" => 2, "snowy" => 2, "spotted" => 2, "sprightly" => 2, "steady" => 2, "sturdy" => 2, "sunlit" => 2,
        "sunny" => 2, "tawny" => 2, "tidy" => 2, "tiny" => 2, "toasty" => 2, "trusty" => 2, "upbeat" => 2,
        "velvet" => 2, "vivid" => 2, "wacky" => 2, "wily" => 2, "windy" => 2, "witty" => 2, "woolly" => 2,
        "zany" => 2, "zesty" => 2
      }.freeze

      NOUNS = {
        "bay" => 1, "bean" => 1, "bear" => 1, "bee" => 1, "bell" => 1, "bloom" => 1, "boat" => 1, "book" => 1,
        "breeze" => 1, "brook" => 1, "cake" => 1, "calf" => 1, "carp" => 1, "clam" => 1, "cliff" => 1, "cloud" => 1,
        "coin" => 1, "colt" => 1, "cove" => 1, "crab" => 1, "crane" => 1, "creek" => 1, "crow" => 1, "crown" => 1,
        "cub" => 1, "dale" => 1, "dawn" => 1, "deer" => 1, "dove" => 1, "drum" => 1, "duck" => 1, "dusk" => 1,
        "elk" => 1, "elm" => 1, "fawn" => 1, "fern" => 1, "fig" => 1, "finch" => 1, "flute" => 1, "fox" => 1,
        "frog" => 1, "glen" => 1, "goose" => 1, "gull" => 1, "hare" => 1, "harp" => 1, "hawk" => 1, "hill" => 1,
        "horn" => 1, "jay" => 1, "kite" => 1, "koi" => 1, "lake" => 1, "lamb" => 1, "lamp" => 1, "lark" => 1,
        "lime" => 1, "loon" => 1, "lynx" => 1, "mole" => 1, "moon" => 1, "moose" => 1, "moss" => 1, "mouse" => 1,
        "newt" => 1, "oak" => 1, "oat" => 1, "peach" => 1, "peak" => 1, "pear" => 1, "pie" => 1, "pike" => 1,
        "pine" => 1, "plum" => 1, "pond" => 1, "quill" => 1, "rain" => 1, "reed" => 1, "reef" => 1, "rock" => 1,
        "sail" => 1, "scarf" => 1, "seal" => 1, "seed" => 1, "shell" => 1, "ship" => 1, "spoon" => 1, "squid" => 1,
        "star" => 1, "stone" => 1, "stork" => 1, "swan" => 1, "tern" => 1, "toad" => 1, "trout" => 1, "vale" => 1,
        "whale" => 1, "wheat" => 1, "wren" => 1, "yak" => 1,
        "acorn" => 2, "almond" => 2, "anchor" => 2, "apple" => 2, "badger" => 2, "banjo" => 2, "basket" => 2,
        "beaver" => 2, "beetle" => 2, "berry" => 2, "biscuit" => 2, "bison" => 2, "button" => 2, "cactus" => 2,
        "camel" => 2, "candle" => 2, "canyon" => 2, "carrot" => 2, "castle" => 2, "cedar" => 2, "cello" => 2,
        "cherry" => 2, "clover" => 2, "comet" => 2, "cookie" => 2, "cottage" => 2, "crystal" => 2, "daisy" => 2,
        "dolphin" => 2, "donkey" => 2, "falcon" => 2, "fiddle" => 2, "garden" => 2, "heron" => 2, "island" => 2,
        "kayak" => 2, "kettle" => 2, "kitten" => 2, "lagoon" => 2, "lantern" => 2, "lemon" => 2, "lily" => 2,
        "llama" => 2, "magpie" => 2, "mango" => 2, "maple" => 2, "marble" => 2, "meadow" => 2, "melon" => 2,
        "mitten" => 2, "monkey" => 2, "muffin" => 2, "olive" => 2, "orchard" => 2, "otter" => 2, "paddle" => 2,
        "pancake" => 2, "panda" => 2, "parrot" => 2, "pebble" => 2, "penguin" => 2, "pepper" => 2, "pillow" => 2,
        "planet" => 2, "pocket" => 2, "pony" => 2, "puffin" => 2, "pumpkin" => 2, "puppy" => 2, "puzzle" => 2,
        "rabbit" => 2, "rainbow" => 2, "raven" => 2, "ribbon" => 2, "river" => 2, "robin" => 2, "rocket" => 2,
        "saddle" => 2, "salmon" => 2, "slipper" => 2, "snowflake" => 2, "sparrow" => 2, "sunbeam" => 2,
        "teacup" => 2, "teapot" => 2, "thistle" => 2, "tiger" => 2, "toucan" => 2, "trumpet" => 2, "tulip" => 2,
        "turtle" => 2, "valley" => 2, "waffle" => 2, "wagon" => 2, "walnut" => 2, "walrus" => 2, "whistle" => 2,
        "willow" => 2, "window" => 2, "zebra" => 2
      }.freeze

      SHORT_ADJECTIVES, LONG_ADJECTIVES = ADJECTIVES.keys.partition { ADJECTIVES[it] == 1 }.map(&:freeze)
      SHORT_NOUNS, LONG_NOUNS = NOUNS.keys.partition { NOUNS[it] == 1 }.map(&:freeze)
      # The pairs, numbered from 0: each short adjective with each long
      # noun, then each long adjective with each short noun.
      SHORT_FIRST = SHORT_ADJECTIVES.size * LONG_NOUNS.size
      SIZE = SHORT_FIRST + (LONG_ADJECTIVES.size * SHORT_NOUNS.size)

      module_function

      def size = SIZE

      # The run's first count names, in rewrite order, or all SIZE of them.
      def names(run_id, count)
        swapped = {}
        Array.new(count.clamp(0, SIZE)) do |position|
          other = position + draw(run_id, position, SIZE - position)
          drawn = swapped.fetch(other, other)
          swapped[other] = swapped.fetch(position, position)
          pair(swapped[position] = drawn)
        end
      end

      # Rewrite number's name in the run, or nil past the last name.
      def name(run_id, number) = (names(run_id, number).last if number.between?(1, SIZE))

      # A search such as rewrite_3 as "Rewrite" and its name, or its number
      # past the last name. Anything else as it is.
      def label(run_id, search)
        number = search.to_s[/\Arewrite_(\d+)\z/, 1] or return search.to_s
        "Rewrite #{name(run_id, number.to_i) || number}"
      end

      # A number below bound, from SHA-256 of the run ID and the position.
      def draw(run_id, position, bound) = Digest::SHA256.hexdigest("#{run_id}\n#{position}").to_i(16) % bound

      def pair(index)
        words = if index < SHORT_FIRST
                  [SHORT_ADJECTIVES[index / LONG_NOUNS.size], LONG_NOUNS[index % LONG_NOUNS.size]]
                else
                  index -= SHORT_FIRST
                  [LONG_ADJECTIVES[index / SHORT_NOUNS.size], SHORT_NOUNS[index % SHORT_NOUNS.size]]
                end
        words.map(&:capitalize).join(" ")
      end
    end
  end
end
