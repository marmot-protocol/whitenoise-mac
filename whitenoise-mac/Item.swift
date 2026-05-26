//
//  Item.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
