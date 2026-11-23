require "test_helper"

# A class body that defines a method twice keeps only the last one, silently:
# designs-canvas had two remember()s, one for the frame's size and one for a
# screen's state, and the size dragged was never kept (Kacper, 2026-11-23).
class StimulusControllersTest < ActiveSupport::TestCase
  KEYWORDS = %w[if for while switch catch function return].freeze
  # A method in a class body: two spaces in, maybe static, async, get or set.
  METHOD = /^  ((?:static )?(?:async )?(?:get |set )?)([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/

  test "no Stimulus controller defines a method twice" do
    twice = Dir[Rails.root.join("app/javascript/controllers/**/*.js").to_s].sort.filter_map do |path|
      names = File.read(path).scan(METHOD).filter_map do |prefix, name|
        next if KEYWORDS.include?(name)

        [ prefix[/static/], prefix[/\b(get|set) /, 1], name ].compact.join(" ")
      end
      repeated = names.tally.select { |_, count| count > 1 }.keys
      "#{Pathname(path).relative_path_from(Rails.root)}: #{repeated.join(', ')}" if repeated.any?
    end

    assert_empty twice
  end
end
