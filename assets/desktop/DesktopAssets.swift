import Foundation

public enum DesktopAssets {
    public static func image(_ name:String)->URL? {
        Bundle.module.url(forResource:name,withExtension:"png",subdirectory:"images")
    }
}
