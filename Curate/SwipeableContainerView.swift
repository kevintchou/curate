//
//  SwipeableContainerView.swift
//  Curate
//
//  Created by Kevin Chou on 11/20/25.
//

import SwiftUI

struct SwipeableContainerView: View {
    @State private var offset: CGFloat = 0
    @State private var baseOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            
            HStack(spacing: 0) {
                // Your new view on the left
                CurateView()
                    .frame(width: screenWidth)
                
                // MainTabView on the right
                MainTabView()
                    .frame(width: screenWidth)
            }
            .offset(x: offset)
            .animation(nil, value: offset) // Disable implicit animations during drag
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        // Calculate new offset based on drag translation
                        let newOffset = baseOffset + value.translation.width
                        
                        // Determine which screen we're on
                        let isOnFirstScreen = baseOffset == 0
                        let isOnLastScreen = baseOffset == -screenWidth
                        
                        // Disable swipe or add strong resistance at edges
                        let clampedOffset: CGFloat
                        
                        if isOnFirstScreen && value.translation.width > 0 {
                            // On first screen, trying to swipe right - block completely
                            clampedOffset = baseOffset
                        } else if isOnLastScreen && value.translation.width < 0 {
                            // On last screen, trying to swipe left - block completely
                            clampedOffset = baseOffset
                        } else if newOffset > 0 {
                            // Trying to go beyond first screen - should never happen now
                            clampedOffset = newOffset * 0.3
                        } else if newOffset < -screenWidth {
                            // Trying to go beyond last screen - should never happen now
                            let excess = newOffset + screenWidth
                            clampedOffset = -screenWidth + (excess * 0.3)
                        } else {
                            // Normal swipe between screens
                            clampedOffset = newOffset
                        }
                        
                        offset = clampedOffset
                    }
                    .onEnded { value in
                        // Calculate velocity (points per second)
                        let velocity = (value.predictedEndTranslation.width - value.translation.width) / 0.3
                        let currentOffset = baseOffset + value.translation.width
                        
                        // Determine which screen we're on
                        let isOnFirstScreen = baseOffset == 0
                        let isOnLastScreen = baseOffset == -screenWidth
                        
                        // Block transitions at edges
                        if (isOnFirstScreen && value.translation.width > 0) || 
                           (isOnLastScreen && value.translation.width < 0) {
                            // Animate back to current position
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                offset = baseOffset
                            }
                            return
                        }
                        
                        // Determine which view to snap to based on position and velocity
                        let shouldShowMainTab: Bool
                        
                        // Very low velocity threshold for quick flicks
                        if abs(velocity) > 100 {
                            shouldShowMainTab = velocity < 0
                        } else {
                            // Position threshold: 25% of screen
                            shouldShowMainTab = currentOffset < -screenWidth * 0.25
                        }
                        
                        // Update base offset first
                        let targetOffset: CGFloat = shouldShowMainTab ? -screenWidth : 0
                        baseOffset = targetOffset
                        
                        // Animate with velocity-aware spring
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0)) {
                            offset = targetOffset
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    SwipeableContainerView()
}
