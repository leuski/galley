//
//  SceneColorSchemeModel.swift
//  Galley
//
//  Created by Anton Leuski on 5/18/26.
//

import GalleyCoreKit
import SwiftUI
import KosmosAppKit

typealias SceneColorSchemeChoiceValue = SceneChoiceValueEnvelope<
  ColorSchemeChoice, SceneChoiceLocalizer<ColorSchemeChoice.Element>>
typealias SceneColorSchemeChoice = SceneChoice<
  ColorSchemeChoice, SceneChoiceLocalizer<ColorSchemeChoice.Element>>
