// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LimeLink",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name:"LimeLinkCore",targets:["LimeLinkCore"]),.library(name:"LimeLinkUI",targets:["LimeLinkUI"]),.executable(name:"LimeLink",targets:["LimeLinkMac"])],
    dependencies: [.package(path:".dev/upstream/apps/ios")],
    targets: [
        .target(name:"LimeLinkCore",dependencies:[.product(name:"LimeIoTKit",package:"ios")],path:"packages/apple/Sources/LimeLinkCore"),
        .target(name:"LimeLinkUI",dependencies:["LimeLinkCore",.product(name:"LimeIoTKit",package:"ios")],path:"packages/apple/Sources/LimeLinkUI"),
        .executableTarget(name:"LimeLinkMac",dependencies:["LimeLinkUI","LimeLinkCore"],path:"apps/macos"),
        .executableTarget(name:"LinkChecks",dependencies:["LimeLinkCore",.product(name:"LimeIoTKit",package:"ios")],path:"packages/apple/Tests"),
        .executableTarget(name:"WorkbenchChecks",dependencies:["LimeLinkUI","LimeLinkCore",.product(name:"LimeIoTKit",package:"ios")],path:"packages/apple/WorkbenchTests")
    ]
)
