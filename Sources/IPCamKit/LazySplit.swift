/// The pieces of a collection between occurrences of `separator`, produced
/// one at a time, like `split(separator:omittingEmptySubsequences:)` without
/// building the array. A server-supplied value (an SDP `fmtp`, up to the
/// 2 MiB body limit) of nothing but separators would otherwise make an array
/// of a million slices, many times the value's size.
struct LazySplitSequence<Base: Collection>: Sequence, IteratorProtocol
where Base.Element: Equatable {
  private let base: Base
  private let separator: Base.Element
  private let omittingEmpty: Bool
  private var position: Base.Index
  private var finished = false

  init(_ base: Base, separator: Base.Element, omittingEmpty: Bool) {
    self.base = base
    self.separator = separator
    self.omittingEmpty = omittingEmpty
    position = base.startIndex
  }

  mutating func next() -> Base.SubSequence? {
    while !finished {
      let end = base[position...].firstIndex(of: separator) ?? base.endIndex
      let piece = base[position..<end]
      if end == base.endIndex {
        finished = true
      } else {
        position = base.index(after: end)
      }
      if !(omittingEmpty && piece.isEmpty) { return piece }
    }
    return nil
  }
}

extension Collection where Element: Equatable {
  /// `split(separator:omittingEmptySubsequences:)`, one piece at a time.
  func lazySplit(
    separator: Element, omittingEmptySubsequences: Bool = true
  ) -> LazySplitSequence<Self> {
    LazySplitSequence(self, separator: separator, omittingEmpty: omittingEmptySubsequences)
  }
}
