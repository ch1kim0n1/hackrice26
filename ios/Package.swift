// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NutriQuest",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NutriQuest", targets: ["NutriQuest"]),
        .library(name: "NutriQuestUI", targets: ["NutriQuestUI"]),
        .library(name: "BattleKit", targets: ["BattleKit"])
    ],
    targets: [
        .target(name: "BattleKit", path: "Sources/BattleKit"),
        .target(
            name: "NutriQuestUI",
            path: "Sources/NutriQuestUI",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "NutriQuest",
            dependencies: ["BattleKit", "NutriQuestUI"],
            path: "Sources/NutriQuest",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BattleKitTests",
            dependencies: ["BattleKit"],
            path: "Tests/BattleKitTests"
        ),
        .testTarget(
            name: "NutriQuestTests",
            dependencies: ["NutriQuest"],
            path: "Tests/NutriQuestTests"
        )
    ]
)
