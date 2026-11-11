import CryptoKit
import Flutter
import Photos

/// Fork (mandeep/photos): small PhotoKit helpers for the two-way mirror.
/// Plain method channel so no Pigeon codegen is needed.
///  - fullAccess -> Bool: whether the app has full (not limited) photo library access
///  - existing {ids: [String]} -> [String]: the ids that still exist in the library
///  - setFavorite {ids: [String], favorite: Bool} -> [String]: ids changed, in ONE performChanges
///    block so iOS asks at most once for the whole batch.
class MirrorApiImpl: NSObject {
  static let channelName = "immich.fork/mirror"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "fullAccess":
        result(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
      case "existing":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        DispatchQueue.global(qos: .utility).async {
          let found = MirrorApiImpl.existing(ids: ids)
          DispatchQueue.main.async { result(found) }
        }
      case "setFavorite":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        let favorite = args?["favorite"] as? Bool ?? false
        MirrorApiImpl.setFavorite(ids: ids, favorite: favorite) { changed in
          DispatchQueue.main.async { result(changed) }
        }
      // Fork background backup: free storage for batch sizing, and background time for the hand-off
      // to the background URLSession when the app leaves the foreground.
      case "freeBytes":
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        result(values?.volumeAvailableCapacityForImportantUsage.map { Int($0) })
      case "beginBackgroundTask":
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "immich.fork.backup") {
          UIApplication.shared.endBackgroundTask(taskId)
        }
        result(taskId.rawValue)
      case "endBackgroundTask":
        if let raw = call.arguments as? Int, raw != UIBackgroundTaskIdentifier.invalid.rawValue {
          UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
        result(nil)
      // Fork library link (11 Nov): metadata only, never downloads from iCloud.
      case "libraryMeta":
        DispatchQueue.global(qos: .userInitiated).async {
          let meta = MirrorApiImpl.libraryMeta()
          DispatchQueue.main.async { result(meta) }
        }
      case "hashOriginals":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        DispatchQueue.global(qos: .userInitiated).async {
          let hashes = MirrorApiImpl.hashOriginals(ids: ids)
          DispatchQueue.main.async { result(hashes) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The original (unedited) resource: what a cable import copies off the phone.
  static func originalResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video] : [.photo]
    if let r = resources.first(where: { wanted.contains($0.type) }) { return r }
    return asset.getResource()
  }

  /// Every asset's metadata plus the user's own albums. Reads PhotoKit's local database only:
  /// file size and local availability come from the resource's stored properties, no data request.
  private static func libraryMeta() -> [String: Any] {
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    let fetch = PHAsset.fetchAssets(with: options)
    var assets: [[String: Any]] = []
    assets.reserveCapacity(fetch.count)
    fetch.enumerateObjects { asset, _, _ in
      autoreleasepool {
        var m: [String: Any] = [
          "id": asset.localIdentifier,
          "type": asset.mediaType.rawValue,
          "w": asset.pixelWidth,
          "h": asset.pixelHeight,
          "fav": asset.isFavorite,
        ]
        if let d = asset.creationDate { m["t"] = Int64(floor(d.timeIntervalSince1970)) }
        if let r = originalResource(for: asset) {
          m["name"] = r.originalFilename
          if let size = r.value(forKey: "fileSize") as? NSNumber { m["size"] = size.int64Value }
          if let local = r.value(forKey: "locallyAvailable") as? NSNumber { m["local"] = local.boolValue }
        }
        assets.append(m)
      }
    }
    var albums: [[String: Any]] = []
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
    collections.enumerateObjects { collection, _, _ in
      autoreleasepool {
        var ids: [String] = []
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        albums.append(["id": collection.localIdentifier, "name": collection.localizedTitle ?? "", "assets": ids])
      }
    }
    return ["assets": assets, "albums": albums]
  }

  /// SHA-1 (base64, like the server checksum) of each asset's ORIGINAL resource, only when it is on the phone:
  /// isNetworkAccessAllowed = false, so an iCloud-only original fails instead of downloading.
  private static func hashOriginals(ids: [String]) -> [String: String] {
    var out: [String: String] = [:]
    if ids.isEmpty { return out }
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var assets: [PHAsset] = []
    fetch.enumerateObjects { a, _, _ in assets.append(a) }
    for asset in assets {
      guard let resource = originalResource(for: asset) else { continue }
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = false
      let sem = DispatchSemaphore(value: 0)
      var hasher = Insecure.SHA1()
      var failed = false
      PHAssetResourceManager.default().requestData(
        for: resource, options: options,
        dataReceivedHandler: { data in hasher.update(data: data) },
        completionHandler: { error in
          failed = error != nil
          sem.signal()
        })
      if sem.wait(timeout: .now() + 120) == .timedOut { continue }
      if !failed { out[asset.localIdentifier] = Data(hasher.finalize()).base64EncodedString() }
    }
    return out
  }

  private static func existing(ids: [String]) -> [String] {
    if ids.isEmpty { return [] }
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
    var found: [String] = []
    assets.enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
    return found
  }

  private static func setFavorite(ids: [String], favorite: Bool, completion: @escaping ([String]) -> Void) {
    if ids.isEmpty { completion([]); return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var toChange: [PHAsset] = []
    assets.enumerateObjects { asset, _, _ in
      if asset.isFavorite != favorite { toChange.append(asset) }
    }
    if toChange.isEmpty { completion(ids); return }
    PHPhotoLibrary.shared().performChanges({
      for asset in toChange {
        PHAssetChangeRequest(for: asset).isFavorite = favorite
      }
    }) { success, error in
      if let error = error {
        print("MirrorApiImpl::setFavorite failed: \(error)")
      }
      completion(success ? ids : [])
    }
  }
}
