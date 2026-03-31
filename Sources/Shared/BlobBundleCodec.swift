#if ENABLE_SYNC

    import ClipKittyRust
    import CloudKit
    import Foundation

    // MARK: - Errors

    enum SyncDataError: LocalizedError {
        case missingAssetFileURL(recordID: String)
        case assetReadFailed(recordID: String, underlying: Error)
        case invalidBlobBundle(recordID: String, underlying: Error)
        case jsonRehydrationFailed(recordID: String, underlying: Error)
        case blobInjectionFailed(recordID: String, path: String)

        var errorDescription: String? {
            switch self {
            case let .missingAssetFileURL(recordID):
                return "CloudKit asset for record \(recordID) did not provide a file URL"
            case let .assetReadFailed(recordID, underlying):
                return "Failed to read CloudKit asset for record \(recordID): \(underlying.localizedDescription)"
            case let .invalidBlobBundle(recordID, underlying):
                return "Failed to decode CloudKit blob bundle for record \(recordID): \(underlying.localizedDescription)"
            case let .jsonRehydrationFailed(recordID, underlying):
                return "Failed to rehydrate CloudKit JSON for record \(recordID): \(underlying.localizedDescription)"
            case let .blobInjectionFailed(recordID, path):
                return "CloudKit blob bundle for record \(recordID) could not be injected at path \(path)"
            }
        }
    }

    // MARK: - Codec

    /// Pure-function codec for blob bundle extraction/injection.
    /// Shared between macOS and iOS sync engines.
    enum BlobBundleCodec {

        /// The CKRecord field name used for blob bundle CKAssets.
        static let blobBundleFieldName = "blobBundleAsset"

        /// Configure a JSON field on a CKRecord, extracting large base64 blobs into a CKAsset.
        /// Returns the temporary file URL if a blob bundle was created (caller must clean up).
        static func configureJSONField(
            _ jsonString: String,
            on record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> URL? {
            if let (strippedJSON, bundle) = extractBase64Bundle(from: jsonString) {
                record[field.recordFieldName] = strippedJSON as CKRecordValue
                let bundleURL = try writeBlobBundle(bundle)
                record[blobBundleFieldName] = CKAsset(fileURL: bundleURL)
                return bundleURL
            }

            record[field.recordFieldName] = jsonString as CKRecordValue
            return nil
        }

        /// Read a JSON field from a CKRecord, rehydrating any blob bundle CKAsset.
        static func rehydratedJSONString(
            for record: CKRecord,
            field: CloudRecordJSONField
        ) throws -> String {
            let jsonString = record[field.recordFieldName] as? String ?? "{}"
            guard let asset = record[blobBundleFieldName] as? CKAsset else {
                return jsonString
            }

            let recordName = record.recordID.recordName
            let bundle = try readBlobBundle(from: asset, recordID: recordName)
            return try inject(blobBundle: bundle, into: jsonString, recordID: recordName)
        }

        /// Convert downloaded CKRecords into FFI-compatible sync records.
        static func convertCloudKitRecords(
            _ changes: SyncZoneChangeResult
        ) throws -> ([SyncEventRecord], [SyncSnapshotRecord]) {
            let eventRecords: [SyncEventRecord] = try changes.events.map { record in
                try SyncEventRecord(
                    eventId: record.recordID.recordName,
                    itemId: record["itemId"] as? String ?? "",
                    originDeviceId: record["originDeviceId"] as? String ?? "",
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    recordedAt: record["recordedAt"] as? Int64 ?? 0,
                    payloadType: record["payloadType"] as? String ?? "",
                    payloadData: rehydratedJSONString(for: record, field: .payloadData)
                )
            }

            let snapshotRecords: [SyncSnapshotRecord] = try changes.snapshots.map { record in
                try SyncSnapshotRecord(
                    itemId: record.recordID.recordName,
                    snapshotRevision: UInt64(record["snapshotRevision"] as? Int64 ?? 0),
                    schemaVersion: UInt32(record["schemaVersion"] as? Int64 ?? 1),
                    coversThroughEvent: record["coversThroughEvent"] as? String,
                    aggregateData: rehydratedJSONString(for: record, field: .aggregateData)
                )
            }

            return (eventRecords, snapshotRecords)
        }

        /// Recursively extract non-empty `_base64` JSON fields into a blob bundle,
        /// returning the stripped JSON and the bundle.
        static func extractBase64Bundle(from jsonString: String) -> (String, BlobBundle)? {
            guard let jsonData = jsonString.data(using: .utf8),
                  var root = try? JSONSerialization.jsonObject(with: jsonData)
            else { return nil }

            var entries: [BlobBundleEntry] = []

            func walk(_ value: inout Any, path: [BlobPathComponent]) {
                if var dict = value as? [String: Any] {
                    for key in dict.keys.sorted() {
                        if let base64Value = dict[key] as? String,
                           key.hasSuffix("_base64"),
                           !base64Value.isEmpty,
                           Data(base64Encoded: base64Value) != nil
                        {
                            entries.append(
                                BlobBundleEntry(
                                    path: path + [.key(key)],
                                    base64Value: base64Value
                                )
                            )
                            dict[key] = ""
                            continue
                        }

                        if var child = dict[key] {
                            walk(&child, path: path + [.key(key)])
                            dict[key] = child
                        }
                    }
                    value = dict
                    return
                }

                if var array = value as? [Any] {
                    for index in array.indices {
                        var child = array[index]
                        walk(&child, path: path + [.index(index)])
                        array[index] = child
                    }
                    value = array
                }
            }

            walk(&root, path: [])

            guard !entries.isEmpty,
                  let strippedData = try? JSONSerialization.data(withJSONObject: root),
                  let strippedString = String(data: strippedData, encoding: .utf8)
            else { return nil }

            return (strippedString, BlobBundle(entries: entries))
        }

        /// Inject blob bundle entries back into a JSON string.
        static func inject(
            blobBundle: BlobBundle,
            into jsonString: String,
            recordID: String
        ) throws -> String {
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw SyncDataError.jsonRehydrationFailed(
                    recordID: recordID,
                    underlying: NSError(
                        domain: "SyncEngine",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "JSON string was not valid UTF-8"]
                    )
                )
            }

            do {
                var root = try JSONSerialization.jsonObject(with: jsonData)
                for entry in blobBundle.entries {
                    guard setJSONValue(
                        entry.base64Value,
                        at: entry.path,
                        in: &root
                    ) else {
                        throw SyncDataError.blobInjectionFailed(
                            recordID: recordID,
                            path: pathDescription(entry.path)
                        )
                    }
                }

                let resultData = try JSONSerialization.data(withJSONObject: root)
                guard let resultString = String(data: resultData, encoding: .utf8) else {
                    throw NSError(
                        domain: "SyncEngine",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to encode rehydrated JSON as UTF-8"]
                    )
                }
                return resultString
            } catch let error as SyncDataError {
                throw error
            } catch {
                throw SyncDataError.jsonRehydrationFailed(
                    recordID: recordID,
                    underlying: error
                )
            }
        }

        /// Write a blob bundle to a temporary file, returning its URL.
        static func writeBlobBundle(_ bundle: BlobBundle) throws -> URL {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json")
            let data = try JSONEncoder().encode(bundle)
            try data.write(to: tempURL)
            return tempURL
        }

        /// Read and decode a blob bundle from a CKAsset, with recordID for error context.
        static func readBlobBundle(from asset: CKAsset, recordID: String) throws -> BlobBundle {
            guard let fileURL = asset.fileURL else {
                throw SyncDataError.missingAssetFileURL(recordID: recordID)
            }
            do {
                let data = try Data(contentsOf: fileURL)
                return try JSONDecoder().decode(BlobBundle.self, from: data)
            } catch let error as DecodingError {
                throw SyncDataError.invalidBlobBundle(recordID: recordID, underlying: error)
            } catch {
                throw SyncDataError.assetReadFailed(recordID: recordID, underlying: error)
            }
        }

        /// Remove temporary blob bundle files.
        static func cleanupTemporaryFiles(_ urls: [URL]) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // MARK: - Internal

        @discardableResult
        private static func setJSONValue(
            _ value: String,
            at path: [BlobPathComponent],
            in node: inout Any
        ) -> Bool {
            guard let component = path.first else { return false }

            switch component {
            case let .key(key):
                guard var dict = node as? [String: Any] else { return false }
                if path.count == 1 {
                    dict[key] = value
                    node = dict
                    return true
                }
                guard var child = dict[key] else { return false }
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                dict[key] = child
                node = dict
                return true

            case let .index(index):
                guard var array = node as? [Any], array.indices.contains(index) else {
                    return false
                }
                if path.count == 1 {
                    array[index] = value
                    node = array
                    return true
                }
                var child = array[index]
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                array[index] = child
                node = array
                return true
            }
        }

        static func pathDescription(_ path: [BlobPathComponent]) -> String {
            if path.isEmpty { return "$" }
            return "$" + path.map { component in
                switch component {
                case let .key(key): return ".\(key)"
                case let .index(index): return "[\(index)]"
                }
            }.joined()
        }
    }

#endif
