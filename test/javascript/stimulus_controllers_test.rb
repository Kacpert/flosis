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

  # Stimulus reads a value from data-<controller>-<name>-value: the Ready
  # screen's Copy set data-clar-copy-value, so it copied nothing and said it
  # had (Kacper, 2026-11-23).
  test "no view sets a Stimulus value without its -value ending" do
    values = Dir[Rails.root.join("app/javascript/controllers/**/*_controller.js").to_s].to_h do |path|
      id = Pathname(path).relative_path_from(Rails.root.join("app/javascript/controllers")).to_s.delete_suffix("_controller.js").tr("_/", "--")
      block = File.read(path)[/static values\s*=\s*\{(.*?)\}\s*$/m, 1].to_s
      [ id, block.scan(/(?:^|[{,])\s*([A-Za-z]\w*)\s*:/).flatten.map(&:underscore) ]
    end
    wrong = Dir[Rails.root.join("app/views/**/*.erb").to_s].flat_map do |view|
      text = File.read(view)
      values.flat_map do |id, names|
        names.filter_map do |name|
          dashed = "data-#{id}-#{name.dasherize}="
          snaked = "#{id.underscore}_#{name}:"
          "#{Pathname(view).relative_path_from(Rails.root)}: #{dashed}" if text.include?(dashed) || text.match?(/\b#{snaked}\s/)
        end
      end
    end

    assert_empty wrong
  end
end
