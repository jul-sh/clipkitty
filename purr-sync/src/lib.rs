use std::cmp::Ordering;
use uuid::Uuid;

pub struct UniFfiTag;

/// Legal payloads for a successful link metadata fetch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataPayload {
    TitleOnly {
        title: String,
        description: Option<String>,
    },
    ImageOnly {
        image_data: Vec<u8>,
        description: Option<String>,
    },
    TitleAndImage {
        title: String,
        image_data: Vec<u8>,
        description: Option<String>,
    },
}

/// Link metadata fetch state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkMetadataState {
    Pending,
    Loaded { payload: LinkMetadataPayload },
    Failed,
}

impl LinkMetadataPayload {
    fn normalized_description(description: Option<&str>) -> Option<String> {
        description
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(String::from)
    }
}

impl LinkMetadataState {
    /// Convert to database fields (title, description, image_data).
    /// NULL title = pending, empty title = failed, otherwise = loaded.
    pub fn to_database_fields(&self) -> (Option<String>, Option<String>, Option<Vec<u8>>) {
        match self {
            LinkMetadataState::Pending => (None, None, None),
            LinkMetadataState::Failed => (Some(String::new()), None, None),
            LinkMetadataState::Loaded { payload } => match payload {
                LinkMetadataPayload::TitleOnly { title, description } => {
                    (Some(title.clone()), description.clone(), None)
                }
                LinkMetadataPayload::ImageOnly {
                    image_data,
                    description,
                } => (None, description.clone(), Some(image_data.clone())),
                LinkMetadataPayload::TitleAndImage {
                    title,
                    image_data,
                    description,
                } => (
                    Some(title.clone()),
                    description.clone(),
                    Some(image_data.clone()),
                ),
            },
        }
    }

    /// Reconstruct from database fields, surfacing invalid combinations instead of
    /// silently coercing them into another state.
    pub fn from_database(
        title: Option<&str>,
        description: Option<&str>,
        image_data: Option<Vec<u8>>,
    ) -> Result<Self, String> {
        let normalized_title = title
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(String::from);
        let normalized_description = LinkMetadataPayload::normalized_description(description);

        match (title, normalized_title, normalized_description, image_data) {
            (None, None, None, None) => Ok(LinkMetadataState::Pending),
            (Some(""), None, None, None) => Ok(LinkMetadataState::Failed),
            (Some(raw_title), None, _, Some(_)) if raw_title.trim().is_empty() => {
                Err("failed link metadata row unexpectedly stored image data".to_string())
            }
            (Some(raw_title), None, Some(_), None) if raw_title.trim().is_empty() => {
                Err("failed link metadata row unexpectedly stored description".to_string())
            }
            (Some(_), Some(title), description, None) => Ok(LinkMetadataState::Loaded {
                payload: LinkMetadataPayload::TitleOnly { title, description },
            }),
            (None, None, description, Some(image_data)) => Ok(LinkMetadataState::Loaded {
                payload: LinkMetadataPayload::ImageOnly {
                    image_data,
                    description,
                },
            }),
            (Some(_), Some(title), description, Some(image_data)) => {
                Ok(LinkMetadataState::Loaded {
                    payload: LinkMetadataPayload::TitleAndImage {
                        title,
                        image_data,
                        description,
                    },
                })
            }
            (None, None, Some(_), None) => {
                Err("link metadata row stored a description without a title or image".to_string())
            }
            (None, Some(_), _, _) => Err(
                "link metadata row normalized to a title without an underlying title column"
                    .to_string(),
            ),
            (Some(raw_title), None, _, None) => Err(format!(
                "link metadata row stored an invalid title value `{raw_title}`"
            )),
            (Some(raw_title), None, _, Some(_)) => Err(format!(
                "link metadata row stored an invalid title value `{raw_title}`"
            )),
        }
    }
}

/// Version clock for a specific sync domain.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncVersion {
    pub counter: i64,
    pub device_id: String,
}

/// Syncable clipboard payloads. File items remain local-only.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SyncContentPayload {
    Text {
        value: String,
    },
    Color {
        value: String,
    },
    Link {
        url: String,
        metadata_state: LinkMetadataState,
    },
    Image {
        data: Vec<u8>,
        description: String,
        thumbnail: Option<Vec<u8>>,
        is_animated: bool,
    },
}

/// Current-state snapshot for a live synced item.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncLiveSnapshot {
    pub global_item_id: String,
    pub content: SyncContentPayload,
    pub source_app: Option<String>,
    pub source_app_bundle_id: Option<String>,
    pub is_bookmarked: bool,
    pub activity_timestamp_unix: i64,
    pub content_version: SyncVersion,
    pub bookmark_version: SyncVersion,
    pub activity_version: SyncVersion,
    pub delete_version: SyncVersion,
}

/// Tombstone snapshot for a deleted synced item.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncTombstoneSnapshot {
    pub global_item_id: String,
    pub content_version: SyncVersion,
    pub delete_version: SyncVersion,
}

/// Synced records are either live or tombstoned.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SyncSnapshot {
    Live { snapshot: SyncLiveSnapshot },
    Tombstone { snapshot: SyncTombstoneSnapshot },
}

/// Snapshot plus the latest transport change tag.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncRecordChange {
    pub snapshot: SyncSnapshot,
    pub record_change_tag: Option<String>,
}

/// Summary returned after applying a remote sync batch.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct SyncApplyReport {
    pub applied_change_count: u64,
    pub fork_count: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncShadowState {
    Live,
    Tombstone,
}

impl SyncShadowState {
    pub fn database_str(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Tombstone => "tombstone",
        }
    }

    pub fn from_database_str(value: &str) -> Result<Self, String> {
        match value {
            "live" => Ok(Self::Live),
            "tombstone" => Ok(Self::Tombstone),
            other => Err(format!("unknown sync shadow state `{other}`")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncShadowRow {
    pub global_item_id: String,
    pub item_id: Option<i64>,
    pub state: SyncShadowState,
    pub record_change_tag: Option<String>,
    pub pending_upload: bool,
    pub content_version: SyncVersion,
    pub bookmark_version: SyncVersion,
    pub activity_version: SyncVersion,
    pub delete_version: SyncVersion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncDomain {
    Content,
    Bookmark,
    Activity,
}

#[derive(Debug, Clone)]
pub enum LocalSyncRecord {
    Missing,
    Live {
        row: SyncShadowRow,
        snapshot: SyncLiveSnapshot,
    },
    Tombstone {
        row: SyncShadowRow,
        snapshot: SyncTombstoneSnapshot,
    },
}

impl LocalSyncRecord {
    pub fn row(&self) -> Option<&SyncShadowRow> {
        match self {
            Self::Missing => None,
            Self::Live { row, .. } | Self::Tombstone { row, .. } => Some(row),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingUploadDisposition {
    Clear,
    MarkPending,
}

#[derive(Debug, Clone)]
pub enum RemoteApplyDecision {
    Ignore,
    UpsertLive {
        snapshot: SyncLiveSnapshot,
        pending_upload: PendingUploadDisposition,
        record_change_tag: Option<String>,
        forked_local_snapshot: Option<SyncLiveSnapshot>,
    },
    UpsertTombstone {
        snapshot: SyncTombstoneSnapshot,
        pending_upload: PendingUploadDisposition,
        record_change_tag: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SnapshotSide {
    Local,
    Remote,
}

pub fn new_sync_identifier() -> String {
    Uuid::new_v4().to_string()
}

pub fn initial_sync_version(device_id: &str, counter: i64) -> SyncVersion {
    SyncVersion {
        counter,
        device_id: device_id.to_string(),
    }
}

pub fn compare_versions(left: &SyncVersion, right: &SyncVersion) -> Ordering {
    left.counter
        .cmp(&right.counter)
        .then_with(|| left.device_id.cmp(&right.device_id))
}

pub fn next_sync_version(previous: &SyncVersion, device_id: &str) -> SyncVersion {
    SyncVersion {
        counter: previous.counter + 1,
        device_id: device_id.to_string(),
    }
}

pub fn same_content_payload(left: &SyncContentPayload, right: &SyncContentPayload) -> bool {
    left == right
}

pub fn plan_remote_apply(
    local: &LocalSyncRecord,
    change: &SyncRecordChange,
) -> RemoteApplyDecision {
    match local {
        LocalSyncRecord::Missing => match &change.snapshot {
            SyncSnapshot::Live { snapshot } => RemoteApplyDecision::UpsertLive {
                snapshot: snapshot.clone(),
                pending_upload: PendingUploadDisposition::Clear,
                record_change_tag: change.record_change_tag.clone(),
                forked_local_snapshot: None,
            },
            SyncSnapshot::Tombstone { snapshot } => RemoteApplyDecision::UpsertTombstone {
                snapshot: snapshot.clone(),
                pending_upload: PendingUploadDisposition::Clear,
                record_change_tag: change.record_change_tag.clone(),
            },
        },
        LocalSyncRecord::Tombstone {
            row,
            snapshot: local_snapshot,
        } => match &change.snapshot {
            SyncSnapshot::Live { .. } => RemoteApplyDecision::Ignore,
            SyncSnapshot::Tombstone {
                snapshot: remote_snapshot,
            } => {
                if compare_versions(
                    &local_snapshot.delete_version,
                    &remote_snapshot.delete_version,
                ) == Ordering::Less
                {
                    return RemoteApplyDecision::UpsertTombstone {
                        snapshot: remote_snapshot.clone(),
                        pending_upload: PendingUploadDisposition::Clear,
                        record_change_tag: change.record_change_tag.clone(),
                    };
                }

                if local_snapshot == remote_snapshot
                    && (row.pending_upload || row.record_change_tag != change.record_change_tag)
                {
                    return RemoteApplyDecision::UpsertTombstone {
                        snapshot: remote_snapshot.clone(),
                        pending_upload: PendingUploadDisposition::Clear,
                        record_change_tag: change.record_change_tag.clone(),
                    };
                }

                RemoteApplyDecision::Ignore
            }
        },
        LocalSyncRecord::Live {
            row,
            snapshot: local_snapshot,
        } => match &change.snapshot {
            SyncSnapshot::Tombstone {
                snapshot: remote_snapshot,
            } => {
                if compare_versions(
                    &local_snapshot.delete_version,
                    &remote_snapshot.delete_version,
                ) == Ordering::Less
                {
                    return RemoteApplyDecision::UpsertTombstone {
                        snapshot: remote_snapshot.clone(),
                        pending_upload: PendingUploadDisposition::Clear,
                        record_change_tag: change.record_change_tag.clone(),
                    };
                }

                RemoteApplyDecision::Ignore
            }
            SyncSnapshot::Live {
                snapshot: remote_snapshot,
            } => {
                let forked_local_snapshot =
                    should_fork_content_conflict(local_snapshot, remote_snapshot)
                        .then(|| local_snapshot.clone());
                let desired_snapshot = merge_live_snapshots(
                    local_snapshot,
                    remote_snapshot,
                    forked_local_snapshot.is_some(),
                );

                if desired_snapshot == *local_snapshot {
                    if desired_snapshot == *remote_snapshot
                        && (row.pending_upload || row.record_change_tag != change.record_change_tag)
                    {
                        return RemoteApplyDecision::UpsertLive {
                            snapshot: desired_snapshot,
                            pending_upload: PendingUploadDisposition::Clear,
                            record_change_tag: change.record_change_tag.clone(),
                            forked_local_snapshot,
                        };
                    }

                    return RemoteApplyDecision::Ignore;
                }

                let pending_upload = if desired_snapshot == *remote_snapshot {
                    PendingUploadDisposition::Clear
                } else {
                    PendingUploadDisposition::MarkPending
                };

                RemoteApplyDecision::UpsertLive {
                    snapshot: desired_snapshot,
                    pending_upload,
                    record_change_tag: change.record_change_tag.clone(),
                    forked_local_snapshot,
                }
            }
        },
    }
}

pub fn sync_shadow_for_live_snapshot(
    snapshot: &SyncLiveSnapshot,
    item_id: i64,
    pending_upload: PendingUploadDisposition,
    record_change_tag: Option<String>,
) -> SyncShadowRow {
    SyncShadowRow {
        global_item_id: snapshot.global_item_id.clone(),
        item_id: Some(item_id),
        state: SyncShadowState::Live,
        record_change_tag,
        pending_upload: pending_upload == PendingUploadDisposition::MarkPending,
        content_version: snapshot.content_version.clone(),
        bookmark_version: snapshot.bookmark_version.clone(),
        activity_version: snapshot.activity_version.clone(),
        delete_version: snapshot.delete_version.clone(),
    }
}

pub fn sync_shadow_for_tombstone_snapshot(
    snapshot: &SyncTombstoneSnapshot,
    existing_row: Option<&SyncShadowRow>,
    pending_upload: PendingUploadDisposition,
    record_change_tag: Option<String>,
) -> SyncShadowRow {
    let (bookmark_version, activity_version) = match existing_row {
        Some(row) => (row.bookmark_version.clone(), row.activity_version.clone()),
        None => (
            initial_sync_version(&snapshot.delete_version.device_id, 0),
            initial_sync_version(&snapshot.delete_version.device_id, 0),
        ),
    };
    SyncShadowRow {
        global_item_id: snapshot.global_item_id.clone(),
        item_id: None,
        state: SyncShadowState::Tombstone,
        record_change_tag,
        pending_upload: pending_upload == PendingUploadDisposition::MarkPending,
        content_version: snapshot.content_version.clone(),
        bookmark_version,
        activity_version,
        delete_version: snapshot.delete_version.clone(),
    }
}

fn should_fork_content_conflict(local: &SyncLiveSnapshot, remote: &SyncLiveSnapshot) -> bool {
    !same_content_payload(&local.content, &remote.content)
        && local.content_version.counter == remote.content_version.counter
        && local.content_version.device_id != remote.content_version.device_id
}

fn merge_live_snapshots(
    local: &SyncLiveSnapshot,
    remote: &SyncLiveSnapshot,
    prefer_remote_content: bool,
) -> SyncLiveSnapshot {
    let content_side = if prefer_remote_content {
        SnapshotSide::Remote
    } else {
        match compare_versions(&local.content_version, &remote.content_version) {
            Ordering::Less => SnapshotSide::Remote,
            Ordering::Greater => SnapshotSide::Local,
            Ordering::Equal => {
                if same_content_payload(&local.content, &remote.content)
                    && local.source_app == remote.source_app
                    && local.source_app_bundle_id == remote.source_app_bundle_id
                {
                    SnapshotSide::Local
                } else {
                    SnapshotSide::Remote
                }
            }
        }
    };

    let bookmark_side = match compare_versions(&local.bookmark_version, &remote.bookmark_version) {
        Ordering::Less => SnapshotSide::Remote,
        Ordering::Greater => SnapshotSide::Local,
        Ordering::Equal => {
            if local.is_bookmarked == remote.is_bookmarked {
                SnapshotSide::Local
            } else {
                SnapshotSide::Remote
            }
        }
    };

    let activity_side = match compare_versions(&local.activity_version, &remote.activity_version) {
        Ordering::Less => SnapshotSide::Remote,
        Ordering::Greater => SnapshotSide::Local,
        Ordering::Equal => {
            if local.activity_timestamp_unix >= remote.activity_timestamp_unix {
                SnapshotSide::Local
            } else {
                SnapshotSide::Remote
            }
        }
    };

    let (content, source_app, source_app_bundle_id, content_version) = match content_side {
        SnapshotSide::Local => (
            local.content.clone(),
            local.source_app.clone(),
            local.source_app_bundle_id.clone(),
            local.content_version.clone(),
        ),
        SnapshotSide::Remote => (
            remote.content.clone(),
            remote.source_app.clone(),
            remote.source_app_bundle_id.clone(),
            remote.content_version.clone(),
        ),
    };

    let (is_bookmarked, bookmark_version) = match bookmark_side {
        SnapshotSide::Local => (local.is_bookmarked, local.bookmark_version.clone()),
        SnapshotSide::Remote => (remote.is_bookmarked, remote.bookmark_version.clone()),
    };

    let (activity_timestamp_unix, activity_version) = match activity_side {
        SnapshotSide::Local => (
            local.activity_timestamp_unix,
            local.activity_version.clone(),
        ),
        SnapshotSide::Remote => (
            remote.activity_timestamp_unix,
            remote.activity_version.clone(),
        ),
    };

    let delete_version = match compare_versions(&local.delete_version, &remote.delete_version) {
        Ordering::Less => remote.delete_version.clone(),
        Ordering::Equal | Ordering::Greater => local.delete_version.clone(),
    };

    SyncLiveSnapshot {
        global_item_id: local.global_item_id.clone(),
        content,
        source_app,
        source_app_bundle_id,
        is_bookmarked,
        activity_timestamp_unix,
        content_version,
        bookmark_version,
        activity_version,
        delete_version,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn version(counter: i64, device_id: &str) -> SyncVersion {
        SyncVersion {
            counter,
            device_id: device_id.to_string(),
        }
    }

    fn text_snapshot(
        global_item_id: &str,
        value: &str,
        is_bookmarked: bool,
        activity_timestamp_unix: i64,
        content_version: SyncVersion,
        bookmark_version: SyncVersion,
        activity_version: SyncVersion,
        delete_version: SyncVersion,
    ) -> SyncLiveSnapshot {
        SyncLiveSnapshot {
            global_item_id: global_item_id.to_string(),
            content: SyncContentPayload::Text {
                value: value.to_string(),
            },
            source_app: None,
            source_app_bundle_id: None,
            is_bookmarked,
            activity_timestamp_unix,
            content_version,
            bookmark_version,
            activity_version,
            delete_version,
        }
    }

    fn live_change(snapshot: SyncLiveSnapshot) -> SyncRecordChange {
        SyncRecordChange {
            snapshot: SyncSnapshot::Live { snapshot },
            record_change_tag: Some("remote-tag".to_string()),
        }
    }

    #[test]
    fn plan_remote_apply_merges_independent_domains_and_marks_pending_when_local_wins() {
        let local_snapshot = text_snapshot(
            "shared",
            "local content",
            false,
            100,
            version(2, "local-device"),
            version(0, "local-device"),
            version(1, "local-device"),
            version(0, "local-device"),
        );
        let local = LocalSyncRecord::Live {
            row: SyncShadowRow {
                global_item_id: "shared".to_string(),
                item_id: Some(41),
                state: SyncShadowState::Live,
                record_change_tag: Some("local-tag".to_string()),
                pending_upload: false,
                content_version: local_snapshot.content_version.clone(),
                bookmark_version: local_snapshot.bookmark_version.clone(),
                activity_version: local_snapshot.activity_version.clone(),
                delete_version: local_snapshot.delete_version.clone(),
            },
            snapshot: local_snapshot.clone(),
        };
        let remote_snapshot = text_snapshot(
            "shared",
            "stale remote content",
            true,
            200,
            version(1, "remote-device"),
            version(1, "remote-device"),
            version(2, "remote-device"),
            version(0, "remote-device"),
        );

        let decision = plan_remote_apply(&local, &live_change(remote_snapshot));
        match decision {
            RemoteApplyDecision::UpsertLive {
                snapshot,
                pending_upload,
                forked_local_snapshot,
                ..
            } => {
                assert_eq!(
                    snapshot.content,
                    SyncContentPayload::Text {
                        value: "local content".to_string(),
                    }
                );
                assert!(snapshot.is_bookmarked);
                assert_eq!(snapshot.activity_timestamp_unix, 200);
                assert_eq!(pending_upload, PendingUploadDisposition::MarkPending);
                assert!(forked_local_snapshot.is_none());
            }
            other => panic!("expected live upsert, got {other:?}"),
        }
    }

    #[test]
    fn plan_remote_apply_forks_concurrent_content_edits() {
        let local_snapshot = text_snapshot(
            "shared",
            "local edit",
            false,
            100,
            version(2, "local-device"),
            version(0, "local-device"),
            version(1, "local-device"),
            version(0, "local-device"),
        );
        let local = LocalSyncRecord::Live {
            row: SyncShadowRow {
                global_item_id: "shared".to_string(),
                item_id: Some(7),
                state: SyncShadowState::Live,
                record_change_tag: Some("local-tag".to_string()),
                pending_upload: false,
                content_version: local_snapshot.content_version.clone(),
                bookmark_version: local_snapshot.bookmark_version.clone(),
                activity_version: local_snapshot.activity_version.clone(),
                delete_version: local_snapshot.delete_version.clone(),
            },
            snapshot: local_snapshot.clone(),
        };
        let remote_snapshot = text_snapshot(
            "shared",
            "remote edit",
            false,
            100,
            version(2, "remote-device"),
            version(0, "remote-device"),
            version(1, "local-device"),
            version(0, "local-device"),
        );

        let decision = plan_remote_apply(&local, &live_change(remote_snapshot.clone()));
        match decision {
            RemoteApplyDecision::UpsertLive {
                snapshot,
                pending_upload,
                forked_local_snapshot,
                ..
            } => {
                assert_eq!(snapshot, remote_snapshot);
                assert_eq!(pending_upload, PendingUploadDisposition::Clear);
                assert_eq!(forked_local_snapshot, Some(local_snapshot));
            }
            other => panic!("expected conflict fork, got {other:?}"),
        }
    }

    #[test]
    fn tombstone_shadow_preserves_bookmark_and_activity_versions() {
        let existing_row = SyncShadowRow {
            global_item_id: "shared".to_string(),
            item_id: Some(9),
            state: SyncShadowState::Live,
            record_change_tag: Some("tag-1".to_string()),
            pending_upload: false,
            content_version: version(3, "device-a"),
            bookmark_version: version(2, "device-b"),
            activity_version: version(4, "device-c"),
            delete_version: version(0, "device-a"),
        };
        let tombstone = SyncTombstoneSnapshot {
            global_item_id: "shared".to_string(),
            content_version: version(3, "device-a"),
            delete_version: version(1, "device-d"),
        };

        let row = sync_shadow_for_tombstone_snapshot(
            &tombstone,
            Some(&existing_row),
            PendingUploadDisposition::Clear,
            Some("tag-2".to_string()),
        );

        assert_eq!(row.state, SyncShadowState::Tombstone);
        assert_eq!(row.item_id, None);
        assert_eq!(row.bookmark_version, existing_row.bookmark_version);
        assert_eq!(row.activity_version, existing_row.activity_version);
        assert_eq!(row.delete_version, tombstone.delete_version);
    }

    #[test]
    fn link_metadata_round_trips_loaded_title_and_image() {
        let original = LinkMetadataState::Loaded {
            payload: LinkMetadataPayload::TitleAndImage {
                title: "ClipKitty".to_string(),
                image_data: vec![1, 2, 3],
                description: Some("Clipboard sync".to_string()),
            },
        };

        let (title, description, image_data) = original.to_database_fields();
        let restored =
            LinkMetadataState::from_database(title.as_deref(), description.as_deref(), image_data)
                .expect("loaded metadata should round-trip");

        assert_eq!(restored, original);
    }
}
