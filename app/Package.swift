// swift-tools-version:5.10
// Приложение Zapret в строке меню — пульт к zapret-mac.sh. Собирается без Xcode:
//   bash app/build.sh   →   app/build/Zapret.app и app/build/Zapret.zip
import PackageDescription

let package = Package(
    name: "Zapret",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Zapret", path: "Sources/Zapret")
    ]
)
