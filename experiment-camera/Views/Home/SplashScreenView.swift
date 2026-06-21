//
//  SplashScreenView.swift
//  experiment-camera
//
//  Created by Nenad BOGOJEVIC on 21/06/2026.
//

import SwiftUI

struct SplashScreenView: View {
    var body: some View {
        ZStack {
            // White background
            Color.white
                .ignoresSafeArea()
            
            // Light azure blue house.circle icon
            Image(systemName: "house.circle")
                .font(.system(size: 100, weight: .thin))
                .foregroundStyle(Color(red: 0.68, green: 0.85, blue: 0.90)) // Light azure blue
        }
    }
}

#Preview {
    SplashScreenView()
}
