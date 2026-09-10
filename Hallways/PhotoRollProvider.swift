//
//  PhotoRollProvider.swift
//  Hallways
//
//  Loads photos from the user's camera roll for the "My Photos" theme —
//  the old "wander through a museum of your own life" idea, now as a
//  texture source instead of a whole game concept. Each wall segment,
//  dead-end cap, and the ceiling gets its own photo (see ContentView's
//  Coordinator.applyPhotoRollTheme, which cycles this pool across
//  however many surfaces the current maze has) instead of one photo
//  repeated everywhere.
//
//  Ordering: sorted oldest-to-newest, then a RANDOM starting point
//  somewhere in the library is picked and `count` photos are read
//  forward in time from there — Eddie's ask: keep them chronological,
//  but don't always start at the very beginning of camera history;
//  start from a random point and let it play forward from there, so a
//  different slice of the timeline shows up each time the maze
//  refreshes.
//
//  Kept separate from WallTheme's bundled-jpg themes since this is
//  fundamentally async and permission-gated, unlike a jpg sitting in
//  the app bundle. Needs NSPhotoLibraryUsageDescription set in the
//  target's Info settings, or requestAuthorization crashes.
//

import Photos
import UIKit

final class PhotoRollProvider {
    static let shared = PhotoRollProvider()
    private init() {}

    /// A maze can have far more wall segments than it's sane to hold
    /// full-size UIImages for at once (a big cross maze can run 60-100+
    /// individual wall boxes) — fetching one distinct photo per wall
    /// risks real memory pressure. Capping the pool here and having
    /// callers cycle through it (see Coordinator.applyPhotoRollTheme)
    /// keeps memory bounded regardless of maze size, at the cost of
    /// some repeats in a very large maze — still far more variety than
    /// the single shared photo this replaced.
    static let maxPoolSize = 24

    /// Independent random picks across the entire accessible image library.
    /// No date window or fetch limit; iCloud originals are eligible too.
    /// Reports each result on the main queue so pictures can appear as they load.
    func randomImages(count: Int, onImage: @escaping (Int, UIImage?) -> Void) {
        guard count > 0 else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    for index in 0..<count { onImage(index, nil) }
                }
                return
            }
            let assets = PHAsset.fetchAssets(with: .image, options: nil)
            guard assets.count > 0 else {
                DispatchQueue.main.async {
                    for index in 0..<count { onImage(index, nil) }
                }
                return
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            for index in 0..<count {
                let asset = assets.object(at: Int.random(in: 0..<assets.count))
                var delivered = false
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 512, height: 512),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    DispatchQueue.main.async {
                        guard !delivered else { return }
                        delivered = true
                        onImage(index, image)
                    }
                }
            }
        }
    }

    /// Requests photo library access if needed and hands back up to
    /// `count` (capped at maxPoolSize) photos, square and ready to
    /// texture a wall with. Calls back on the main thread. Returns an
    /// empty array if access is denied/restricted or there are no
    /// photos — callers should leave whatever's currently showing alone
    /// in that case rather than clearing it to blank.
    func recentImages(count: Int, completion: @escaping ([UIImage]) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let take = min(max(count, 1), Self.maxPoolSize)

            // Oldest-first, so a run of `take` consecutive photos
            // starting anywhere in the fetch result reads as a forward
            // walk through time — "the beginning of camera time" is
            // index 0 here.
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

            guard assets.count > 0 else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let actualTake = min(take, assets.count)
            // Random starting point, but clamped so there are always
            // `actualTake` photos left to read forward from it.
            let maxStart = max(0, assets.count - actualTake)
            let start = Int.random(in: 0...maxStart)

            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = false
            requestOptions.isNetworkAccessAllowed = true // let an iCloud-only original download
            requestOptions.deliveryMode = .highQualityFormat

            // Square + fill-cropped so it drops into the wall/ceiling
            // materials exactly like the bundled jpgs, no stretching.
            // 512 (not the original 1024) since we're now potentially
            // holding up to maxPoolSize of these in memory at once
            // instead of just 2.
            let targetSize = CGSize(width: 512, height: 512)
            var results: [UIImage?] = Array(repeating: nil, count: actualTake)
            let group = DispatchGroup()
            let manager = PHImageManager.default()

            // Index results by their offset from `start`, not by
            // completion order — PHImageManager's requests can finish
            // out of order, and offset-indexing is what keeps the
            // final array in true chronological order regardless.
            for offset in 0..<actualTake {
                let asset = assets.object(at: start + offset)
                group.enter()
                manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                    results[offset] = image
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                completion(results.compactMap { $0 })
            }
        }
    }
}
