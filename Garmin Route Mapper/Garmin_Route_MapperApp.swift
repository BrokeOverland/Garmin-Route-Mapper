//
//  Garmin_Route_MapperApp.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import SwiftUI
import CoreData

@main
struct Garmin_Route_MapperApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
