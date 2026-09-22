import Photos
import UIKit

/// Fetches the full authorized image library. Only recent identifiers, never a
/// restricted image/asset pool, are retained to reduce repeats across callers.
final class PhotoRollProvider {
    static let shared = PhotoRollProvider()
    private init() {}
    private var recentIdentifiers: [String] = []

    // Eddie, Sept 17 (startup permission gate): a standalone
    // authorization check/request, reusing the exact same
    // PHPhotoLibrary.requestAuthorization call every randomImages()
    // request already makes below -- just without fetching or
    // delivering any images. Lets ContentView's startup gate learn
    // the Photos decision is made without a second permission system.
    static func resolveAuthorization(completion: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            DispatchQueue.main.async { completion() }
        }
    }

    static func sampleIndices(total: Int, count: Int, avoiding: Set<Int> = []) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        let shuffled = Array(0..<total).shuffled()
        let order = shuffled.filter { !avoiding.contains($0) } + shuffled.filter { avoiding.contains($0) }
        // Exhaust the full library before repeating within a request.
        return (0..<count).map { order[$0 % total] }
    }

    private static func describeAuthStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "FULL"
        case .limited: return "LIMITED (only user-selected photos)"
        case .denied: return "DENIED"
        case .restricted: return "RESTRICTED"
        case .notDetermined: return "NOT_DETERMINED"
        @unknown default: return "UNKNOWN"
        }
    }

    /// Fetches one specific camera-roll photo by its PHAsset local
    /// identifier -- for the Change Picture menu, where a picture that
    /// was already given an explicit camera-roll choice needs that
    /// EXACT photo back on every rebuild, not a fresh random one.
    /// Same authorization-then-fetch shape as randomImages below, just
    /// for a single known asset instead of a random sample. Delivers
    /// nil (not a crash) if the asset is missing/inaccessible now --
    /// the caller already falls back to a placeholder for that.
    func image(forIdentifier identifier: String, caller: String, completion: @escaping (UIImage?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    completion(nil)
                    return
                }
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = assets.firstObject else {
                    navLog("PHOTODIAG caller=\(caller) identifier=\(identifier) ASSET_NOT_FOUND")
                    completion(nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                var delivered = false
                PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    DispatchQueue.main.async {
                        guard !delivered else { return }
                        delivered = true
                        completion(image)
                    }
                }
            }
        }
    }

    /// One random camera-roll photo PLUS its identifier -- for the
    /// Change Picture menu's "Random Photo" action, which (unlike
    /// randomImages below) needs to know WHICH asset was picked so it
    /// can be persisted as this picture's new explicit choice, not
    /// just shown once and forgotten. Reuses the same recentIdentifiers
    /// avoidance randomImages already does, so "Random Photo" doesn't
    /// repeat whatever this or any other picture most recently showed.
    func randomImageWithIdentifier(caller: String, completion: @escaping (String?, UIImage?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    completion(nil, nil)
                    return
                }
                let assets = PHAsset.fetchAssets(with: .image, options: nil)
                let total = assets.count
                guard total > 0 else {
                    completion(nil, nil)
                    return
                }
                let recent = Array(self.recentIdentifiers.suffix(min(256, total - 1)))
                let recentAssets = PHAsset.fetchAssets(withLocalIdentifiers: recent, options: nil)
                var avoided = Set<Int>()
                recentAssets.enumerateObjects { asset, _, _ in
                    let index = assets.index(of: asset)
                    if index != NSNotFound { avoided.insert(index) }
                }
                let index = Self.sampleIndices(total: total, count: 1, avoiding: avoided).first ?? 0
                let asset = assets.object(at: index)
                self.recentIdentifiers.append(asset.localIdentifier)
                self.recentIdentifiers = Array(self.recentIdentifiers.suffix(256))
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                var delivered = false
                PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    DispatchQueue.main.async {
                        guard !delivered else { return }
                        delivered = true
                        navLog("PHOTODIAG caller=\(caller) RANDOM_PICKED id=\(asset.localIdentifier) image=\(image != nil)")
                        completion(asset.localIdentifier, image)
                    }
                }
            }
        }
    }

    func randomImages(count: Int, caller: String, onImage: @escaping (Int, UIImage?) -> Void) {
        guard count > 0 else { return }
        let requestID = UUID().uuidString
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                navLog("PHOTODIAG request=\(requestID) caller=\(caller) auth=\(Self.describeAuthStatus(status))")
                guard status == .authorized || status == .limited else {
                    for i in 0..<count { onImage(i, nil) }
                    return
                }
                let assets = PHAsset.fetchAssets(with: .image, options: nil)
                let total = assets.count
                navLog("PHOTODIAG request=\(requestID) caller=\(caller) totalAccessibleCount=\(total)")
                guard total > 0 else {
                    for i in 0..<count { onImage(i, nil) }
                    return
                }
                // Leave at least one eligible asset even in a very small library.
                let recent = Array(self.recentIdentifiers.suffix(min(256, total - 1)))
                let recentAssets = PHAsset.fetchAssets(withLocalIdentifiers: recent, options: nil)
                var avoided = Set<Int>()
                recentAssets.enumerateObjects { asset, _, _ in
                    let index = assets.index(of: asset)
                    if index != NSNotFound { avoided.insert(index) }
                }
                let selected = Self.sampleIndices(total: total, count: count, avoiding: avoided)
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                for (surface, index) in selected.enumerated() {
                    let asset = assets.object(at: index)
                    self.recentIdentifiers.append(asset.localIdentifier)
                    navLog("PHOTODIAG request=\(requestID) caller=\(caller)[\(surface)] total=\(total) index=\(index) id=\(asset.localIdentifier) created=\(asset.creationDate.map { String(describing: $0) } ?? "nil")")
                    var delivered = false
                    PHImageManager.default().requestImage(for: asset,
                        targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, info in
                        guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                        DispatchQueue.main.async {
                            guard !delivered else { return }
                            delivered = true
                            navLog("PHOTODIAG result request=\(requestID) caller=\(caller)[\(surface)] id=\(asset.localIdentifier) image=\(image != nil) cloud=\(String(describing: info?[PHImageResultIsInCloudKey])) error=\(String(describing: info?[PHImageErrorKey])) cancelled=\(String(describing: info?[PHImageCancelledKey]))")
                            onImage(surface, image)
                        }
                    }
                }
                self.recentIdentifiers = Array(self.recentIdentifiers.suffix(256))
            }
        }
    }
}
