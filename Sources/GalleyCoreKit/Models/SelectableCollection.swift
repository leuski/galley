//
//  SelectableCollection.swift
//  MarkdownPreviewer
//
//  Created by Anton Leuski on 5/3/26.
//

public protocol SelectableCollectionElement: Hashable, Codable {
  associatedtype Value
  init(_ value: Value)
  @MainActor var name: String { get }
}

@Observable @MainActor
final class SelectableCollection<Source, Element>
where Source: Collection, Element: SelectableCollectionElement,
      Element.Value == Source.Element
{
  public var elements: [Element] = []
  public var selected: Element
  public init(elements: Source, selected: Element) {
    self.elements = elements.map { Element($0) }
    self.selected = selected
  }
}
