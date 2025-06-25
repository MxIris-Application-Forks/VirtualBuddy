import Foundation
import BuddyFoundation
import OSLog

private let matchLogger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "SoftwareCatalog+DownloadMatching")

public extension URL {
    private static let virtualBuddySoftwareCatalogDataKey = "codes.rambo.VirtualBuddy.SoftwareCatalogData"

    /// Custom metadata stored by VirtualBuddy as an extended attribute.
    /// This is used to match restore images with those in a software catalog even if they are
    /// renamed by the user or moved within the same volume.
    struct VirtualBuddyCatalogData: Codable, Hashable, Sendable {
        /// The build number for the OS version represented by the restore image file.
        public var build: String
        /// The original name of the corresponding file in the software catalog.
        public var filename: String

        public init(build: String, filename: String) {
            self.build = build
            self.filename = filename
        }

        public init(_ image: RestoreImage) {
            self.init(build: image.build, filename: image.url.lastPathComponent)
        }
    }

    var vb_softwareCatalogData: VirtualBuddyCatalogData? {
        get {
            if let value: VirtualBuddyCatalogData = vb_decodeExtendedAttribute(forKey: Self.virtualBuddySoftwareCatalogDataKey) {
                value
            } else if let downloadedFromURL = vb_whereFromsSpotlightMetadata.first,
                      let build = downloadedFromURL.lastPathComponent.matchAppleOSBuild()
            {
                /// The `com.apple.metadata:kMDItemWhereFroms` extended attribute can be used to determine where a file was originally downloaded from.
                /// If the original download URL had a well-formed OS version build in it, then we can use that attribute even if the file doesn't have the custom VirtualBuddy attribute.
                VirtualBuddyCatalogData(build: build, filename: downloadedFromURL.lastPathComponent)
            } else {
                nil
            }
        }
        nonmutating set {
            guard let newValue else {
                try? vb_removeExtendedAttribute(forKey: Self.virtualBuddySoftwareCatalogDataKey)
                return
            }

            try? vb_encodeExtendedAttribute(newValue, forKey: Self.virtualBuddySoftwareCatalogDataKey)
        }
    }
}

extension URL {
    /// Parses a Spotlight attribute that includes the URL that was used to download the file.
    /// This attribute is added automatically and can be used when matching local files with software catalog contents.
    var vb_whereFromsSpotlightMetadata: [URL] {
        guard let data = vb_extendedAttributeData(forKey: "com.apple.metadata:kMDItemWhereFroms", base64: false) else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any] else { return [] }

        return plist
            .compactMap { $0 as? String }
            .compactMap { URL(string: $0) }
    }

    /// Loads properties that can be used to match a local file URL with a restore image in the software catalog.
    /// Used when matching user-provided restore image files or previously-downloaded restore images with catalog content.
    struct RestoreImageStub: Hashable, Sendable, DownloadableCatalogContent, CustomStringConvertible {
        var id: String { build }
        var build: String
        var url: URL

        init(build: String, url: URL) {
            self.build = build
            self.url = url
        }

        init(url: URL) {
            /// We need some way to determine the OS build corresponding to this file URL.
            /// This will be first read from the extended attributes set by the app itself when it downloads a software image.
            /// This metadata will survive file renames and files being moved within the same volume.
            /// If no metadata can be found, attempt to parse an OS build string from the file name itself.
            let build = url.vb_softwareCatalogData?.build ?? url.lastPathComponent.matchAppleOSBuild() ?? ""

            self.init(build: build, url: url)
        }

        var description: String { "\(url.lastPathComponent) (build \(build.isEmpty ? "?" : build))" }
    }

    /// Container for properties of a restore image that can be inferred from a local file by reading from extended attributes or parsing from the file name.
    var vb_restoreImageStub: RestoreImageStub { RestoreImageStub(url: self) }
}

public extension SoftwareCatalog {
    /// Returns the restore image in the catalog that corresponds to the restore image in the file URL.
    ///
    /// This matches local restore images with catalog images by file name, build number, or using extended attributes that
    /// the app automatically sets on restore images downloaded through the app.
    func restoreImageMatchingDownloadableCatalogContent(at fileURL: URL) -> RestoreImage? {
        restoreImages.vb_elementMatchingDownloadableCatalogContent(at: fileURL)
    }
}

public extension ResolvedCatalog {
    func restoreImageMatchingDownloadableCatalogContent(at fileURL: URL) -> ResolvedRestoreImage? {
        let restoreImages: [ResolvedRestoreImage] = groups.flatMap(\.restoreImages)
        return restoreImages.vb_elementMatchingDownloadableCatalogContent(at: fileURL)
    }
}

extension Array where Element: DownloadableCatalogContent {
    func vb_elementMatchingDownloadableCatalogContent(at url: URL) -> Element? {
        if let match = first(where: { $0.url.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) {
            matchLogger.debug("Matched by file name: \(url.lastPathComponent.quoted) <> \(match.url.lastPathComponent.quoted)")
            return match
        } else if url.isFileURL,
                  let catalogData = url.vb_softwareCatalogData,
                  let match = first(where: { $0.build == catalogData.build || $0.url.lastPathComponent.caseInsensitiveCompare(catalogData.filename) == .orderedSame }) {
            matchLogger.debug("Matched by metadata: \(url.lastPathComponent.quoted) <> \(match.url.lastPathComponent.quoted)")
            return match
        } else if let build = url.lastPathComponent.matchAppleOSBuild(),
                  let match = first(where: { $0.build.caseInsensitiveCompare(build) == .orderedSame })
        {
            matchLogger.debug("Matched by build: \(url.lastPathComponent.quoted) <> \(match.url.lastPathComponent.quoted)")
            return match
        } else {
            return nil
        }
    }
}

