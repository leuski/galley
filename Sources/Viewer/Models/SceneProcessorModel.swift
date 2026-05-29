//
//  SceneProcessorModel.swift
//  Galley
//

import GalleyCoreKit
import KosmosAppKit
import SwiftUI

typealias SceneProcessorChoiceValue = SceneChoiceValueEnvelope<
  ProcessorChoice, SceneChoiceLocalizer<ProcessorChoice.Element>>
typealias SceneProcessorChoice = SceneChoice<
  ProcessorChoice, SceneChoiceLocalizer<ProcessorChoice.Element>>
