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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
