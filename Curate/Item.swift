//
//  Item.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
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
