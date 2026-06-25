//
//  ChoiceModel+Localization.swift
//  Galley
//
//  Created by Anton Leuski on 5/29/26.
//

import SwiftUI

public struct SceneChoiceLocalizer<Value>: SceneChoiceValueEnvelopeLocalizer<
Value>
where Value: ChoiceValue
{
  @MainActor
  public static func stringResource(value: Value) -> LocalizedStringResource {
    LocalizedStringResource(
      "Global (\(String(localized: value.name)))",
      bundle: .galleyCoreKit)
  }
}
