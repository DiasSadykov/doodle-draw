import SwiftUI

enum DoodleTheme {
    static let pink = Color(red: 1, green: 0.176, blue: 0.333) // #FF2D55
    static let paper = Color(red: 1, green: 0.988, blue: 0.961) // #FFFCF5
    static let paperDim = Color(red: 0.937, green: 0.918, blue: 0.875) // #EFEADF

    static let inks: [Color] = [
        Color(red: 0.110, green: 0.110, blue: 0.118), // #1C1C1E
        pink,
        Color(red: 0, green: 0.478, blue: 1), // #007AFF
        Color(red: 0.204, green: 0.780, blue: 0.349), // #34C759
        Color(red: 1, green: 0.584, blue: 0), // #FF9500
    ]

    static let photoInks: [Color] = [
        .white,
        pink,
        Color(red: 1, green: 0.8, blue: 0), // #FFCC00
        Color(red: 0, green: 0.478, blue: 1),
        Color(red: 0.110, green: 0.110, blue: 0.118),
    ]
}
