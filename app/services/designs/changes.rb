# What a branch changed against its base, screen by screen (Workshop Designs
# v2's Changes): the screens that differ, and each one's HTML with
# data-flosis-change="new" or "updated" on the smallest elements that differ,
# for the runtime to outline. Screens are compared with their components pulled
# in (Designs::Includes), so a changed component changes every screen using it.
#
# base and head are Designs::Screens of the two refs. A screen the base lacks is
# new as a whole: its <body> is marked.
class Designs::Changes
  # root: as Designs::Includes takes it, for markup published beside a screen.
  def initialize(base:, head:, root: nil)
    @base = base
    @head = head
    @root = root
  end

  # [{ context:, screen:, kind: "new" | "updated" }], in the head's order.
  def changed
    @changed ||= @head.screens.filter_map do |screen|
      kind = kind_of(screen[:context], screen[:id])
      { context: screen[:context], screen: screen[:id], kind: kind } if kind
    end
  end

  def marked_html(context, id)
    head = document(@head, context, id) or return
    base = document(@base, context, id)
    if base
      Diff.new(base.at("body"), head.at("body")).apply!
    else
      head.at("body")&.set_attribute("data-flosis-change", "new")
    end
    head.to_html
  end

  private

  def kind_of(context, id)
    base = document(@base, context, id) or return "new"

    "updated" if Diff.new(base.at("body"), document(@head, context, id).at("body")).changed?
  end

  def document(screens, context, id)
    html = screens.html(context, id) or return
    Nokogiri::HTML5(Designs::Includes.expand(html, reader: screens.reader, root: @root))
  end

  # Two element trees, compared child list by child list: first the children
  # that are identical, text included (a longest common subsequence), then, in
  # each gap between them, a head element is paired with a base element of the
  # same tag (and class, when one has it) and compared further. An element left
  # over in the head is new; a base child left over, or text that changed,
  # marks the parent updated; so do attributes that differ. Only the outermost
  # mark of a branch of the tree is kept.
  class Diff
    IGNORED = %w[script style template].freeze

    def initialize(base, head)
      @marks = {}
      @changed = false
      walk(base, head) if base && head
    end

    def changed? = @changed

    def apply!
      @marks.each { |node, kind| node.set_attribute("data-flosis-change", kind) unless node.ancestors.any? { |up| @marks.key?(up) } }
    end

    private

    def walk(base, head)
      mark(head, "updated") unless attributes(base) == attributes(head)
      olds = kids(base)
      news = kids(head)
      from_old = from_new = 0
      (lcs(olds, news) << [ olds.size, news.size ]).each do |i, j|
        settle(head, olds[from_old...i], news[from_new...j])
        from_old = i + 1
        from_new = j + 1
      end
    end

    def settle(parent, olds, news)
      return if olds.empty? && news.empty?

      @changed = true
      left = olds.dup
      news.each do |node|
        twin = node.element? && (left.find { |old| old.element? && old.name == node.name && old["class"] == node["class"] } ||
                                 left.find { |old| old.element? && old.name == node.name })
        if twin
          left.delete(twin)
          walk(twin, node)
        elsif node.element?
          mark(node, "new")
        else
          mark(parent, "updated")
        end
      end
      mark(parent, "updated") if left.any?
    end

    def mark(node, kind)
      @changed = true
      @marks[node] ||= kind
    end

    def kids(node)
      node.children.select do |child|
        (child.element? && !IGNORED.include?(child.name)) || (child.text? && child.text.strip.present?)
      end
    end

    def attributes(node)
      node.attribute_nodes.to_h { |attribute| [ attribute.name, attribute.name == "class" ? attribute.value.split.sort.join(" ") : attribute.value ] }
    end

    # Text is compared word by word, so whitespace between tags never counts.
    def signature(node)
      return [ "#text", node.text.squish ] unless node.element?

      [ node.name, attributes(node), node.xpath(".//text()").map { |text| text.text.squish }.reject(&:empty?).join(" ") ]
    end

    # The index pairs of a longest common subsequence of the two lists.
    def lcs(olds, news)
      a = olds.map { |node| signature(node) }
      b = news.map { |node| signature(node) }
      table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
      a.size.downto(0) do |i|
        b.size.downto(0) do |j|
          next if i == a.size || j == b.size

          table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [ table[i + 1][j], table[i][j + 1] ].max
        end
      end
      pairs = []
      i = j = 0
      while i < a.size && j < b.size
        if a[i] == b[j]
          pairs << [ i, j ]
          i += 1
          j += 1
        elsif table[i + 1][j] >= table[i][j + 1]
          i += 1
        else
          j += 1
        end
      end
      pairs
    end
  end
end
