//
//  AppleHomeApp.swift
//  AppleHome
//
//  Created by Jitwisut Thobut on 11/9/2569 BE.
//

import SwiftUI

@main
struct AppleHomeApp: App {
    /// Built here (not in a view) so background relaunches from a geofence event still
    /// start the location monitor and can switch lights on.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
