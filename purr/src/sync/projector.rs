//! Sync projector — applies events to aggregate state with conflict resolution.
//!
//! Conflict rules:
//! - bookmark vs content edit: both apply (independent domains)
//! - bookmark vs debookmark: latest bookmark-domain version wins
//! - stale bookmark/touch against tombstone: ignore
//! - edit vs delete from stale base: fork if content was user-authored
//! - edit vs edit from same base with different text: fork into new logical item
//! - metadata events (link preview, image description) lose to newer user edits

use crate::sync::types::*;

/// Apply a single event payload to an existing aggregate.
///
/// The caller is responsible for dedup checking (`sync_dedup`) before calling this.
pub fn apply_event(
    aggregate: Option<&ItemAggregate>,
    payload: &ItemEventPayload,
) -> ApplyResult {
    match payload {
        ItemEventPayload::ItemCreated { snapshot } => apply_item_created(aggregate, snapshot),
        ItemEventPayload::TextEdited {
            new_text,
            base_content_version,
        } => apply_text_edited(aggregate, new_text, *base_content_version),
        ItemEventPayload::BookmarkSet {
            base_bookmark_version,
        } => apply_bookmark_set(aggregate, *base_bookmark_version),
        ItemEventPayload::BookmarkCleared {
            base_bookmark_version,
        } => apply_bookmark_cleared(aggregate, *base_bookmark_version),
        ItemEventPayload::ItemDeleted {
            base_existence_version,
        } => apply_item_deleted(aggregate, *base_existence_version),
        ItemEventPayload::ItemTouched {
            new_last_used_at_unix,
            base_touch_version,
        } => apply_item_touched(aggregate, *new_last_used_at_unix, *base_touch_version),
        ItemEventPayload::LinkMetadataUpdated {
            metadata,
            base_metadata_version,
        } => apply_link_metadata_updated(aggregate, metadata, *base_metadata_version),
        ItemEventPayload::ImageDescriptionUpdated {
            description,
            base_content_version,
        } => apply_image_description_updated(aggregate, description, *base_content_version),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-payload apply functions
// ─────────���───────────────────���─────────────────────────────��─────────────────

fn apply_item_created(
    aggregate: Option<&ItemAggregate>,
    snapshot: &ItemSnapshotData,
) -> ApplyResult {
    if aggregate.is_some() {
        // Item already exists — this is a duplicate ItemCreated.
        return ApplyResult::Ignored(IgnoreReason::AlreadyApplied);
    }

    let versions = VersionVector {
        content: 1,
        bookmark: if snapshot.is_bookmarked { 1 } else { 0 },
        existence: 1,
        touch: 1,
        metadata: 1,
    };

    let new_aggregate = ItemAggregate::Live(LiveItemState {
        snapshot: snapshot.clone(),
        versions,
    });

    let mut bumped_domains = vec![
        VersionDomain::Content,
        VersionDomain::Existence,
        VersionDomain::Touch,
        VersionDomain::Metadata,
    ];
    if snapshot.is_bookmarked {
        bumped_domains.push(VersionDomain::Bookmark);
    }

    ApplyResult::Applied(ProjectionDelta {
        new_aggregate,
        bumped_domains,
        read_model_dirty: true,
        index_dirty: true,
    })
}

fn apply_text_edited(
    aggregate: Option<&ItemAggregate>,
    new_text: &str,
    base_content_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            // Edit against a tombstone: fork to preserve user-authored content.
            return fork_from_text_edit(agg, new_text);
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.content;
            if base_content_version < current {
                // Stale: someone else already edited from a newer base.
                // Fork to preserve both edits.
                return fork_from_text_edit(agg, new_text);
            }
            if base_content_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Content,
                    event_base: base_content_version,
                    current,
                });
            }

            // Base matches — apply.
            let mut new_snapshot = live.snapshot.clone();
            new_snapshot.content_text = new_text.to_string();
            if let TypeSpecificData::Text { ref mut value } = new_snapshot.type_specific {
                *value = new_text.to_string();
            }
            new_snapshot.content_hash = crate::models::StoredItem::hash_string(new_text);

            let mut new_versions = live.versions;
            new_versions.content += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Content],
                read_model_dirty: true,
                index_dirty: true,
            })
        }
    }
}

fn apply_bookmark_set(
    aggregate: Option<&ItemAggregate>,
    base_bookmark_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.bookmark;
            if base_bookmark_version < current {
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Bookmark,
                    event_base: base_bookmark_version,
                    current,
                });
            }
            if base_bookmark_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Bookmark,
                    event_base: base_bookmark_version,
                    current,
                });
            }

            let mut new_snapshot = live.snapshot.clone();
            new_snapshot.is_bookmarked = true;
            let mut new_versions = live.versions;
            new_versions.bookmark += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Bookmark],
                read_model_dirty: true,
                index_dirty: false,
            })
        }
    }
}

fn apply_bookmark_cleared(
    aggregate: Option<&ItemAggregate>,
    base_bookmark_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.bookmark;
            if base_bookmark_version < current {
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Bookmark,
                    event_base: base_bookmark_version,
                    current,
                });
            }
            if base_bookmark_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Bookmark,
                    event_base: base_bookmark_version,
                    current,
                });
            }

            let mut new_snapshot = live.snapshot.clone();
            new_snapshot.is_bookmarked = false;
            let mut new_versions = live.versions;
            new_versions.bookmark += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Bookmark],
                read_model_dirty: true,
                index_dirty: false,
            })
        }
    }
}

fn apply_item_deleted(
    aggregate: Option<&ItemAggregate>,
    base_existence_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.existence;
            if base_existence_version < current {
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Existence,
                    event_base: base_existence_version,
                    current,
                });
            }
            if base_existence_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Existence,
                    event_base: base_existence_version,
                    current,
                });
            }

            let mut new_versions = live.versions;
            new_versions.existence += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Tombstoned(TombstoneState {
                    deleted_at_unix: chrono::Utc::now().timestamp(),
                    versions: new_versions,
                    content_type: live.snapshot.content_type.clone(),
                }),
                bumped_domains: vec![VersionDomain::Existence],
                read_model_dirty: true,
                index_dirty: true,
            })
        }
    }
}

fn apply_item_touched(
    aggregate: Option<&ItemAggregate>,
    new_last_used_at_unix: i64,
    base_touch_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.touch;
            if base_touch_version < current {
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Touch,
                    event_base: base_touch_version,
                    current,
                });
            }
            if base_touch_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Touch,
                    event_base: base_touch_version,
                    current,
                });
            }

            let mut new_snapshot = live.snapshot.clone();
            new_snapshot.timestamp_unix = new_last_used_at_unix;
            let mut new_versions = live.versions;
            new_versions.touch += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Touch],
                read_model_dirty: true,
                index_dirty: false,
            })
        }
    }
}

fn apply_link_metadata_updated(
    aggregate: Option<&ItemAggregate>,
    metadata: &LinkMetadataSnapshot,
    base_metadata_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.metadata;
            if base_metadata_version < current {
                // Metadata events lose to newer edits.
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Metadata,
                    event_base: base_metadata_version,
                    current,
                });
            }
            if base_metadata_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Metadata,
                    event_base: base_metadata_version,
                    current,
                });
            }

            let mut new_snapshot = live.snapshot.clone();
            if let TypeSpecificData::Link {
                metadata: ref mut link_meta,
                ..
            } = new_snapshot.type_specific
            {
                *link_meta = Some(metadata.clone());
            }
            let mut new_versions = live.versions;
            new_versions.metadata += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Metadata],
                read_model_dirty: true,
                index_dirty: false,
            })
        }
    }
}

fn apply_image_description_updated(
    aggregate: Option<&ItemAggregate>,
    description: &str,
    base_content_version: u64,
) -> ApplyResult {
    let Some(agg) = aggregate else {
        return ApplyResult::Deferred(DeferredReason::MissingItem);
    };

    match agg {
        ItemAggregate::Tombstoned(_) => {
            ApplyResult::Ignored(IgnoreReason::OperationOnTombstone)
        }
        ItemAggregate::Live(live) => {
            let current = live.versions.content;
            // Image description is a metadata-class update that loses to newer content edits.
            if base_content_version < current {
                return ApplyResult::Ignored(IgnoreReason::StaleVersion {
                    domain: VersionDomain::Content,
                    event_base: base_content_version,
                    current,
                });
            }
            if base_content_version > current {
                return ApplyResult::Deferred(DeferredReason::FutureVersion {
                    domain: VersionDomain::Content,
                    event_base: base_content_version,
                    current,
                });
            }

            let mut new_snapshot = live.snapshot.clone();
            new_snapshot.content_text = description.to_string();
            if let TypeSpecificData::Image {
                description: ref mut desc,
                ..
            } = new_snapshot.type_specific
            {
                *desc = description.to_string();
            }
            let mut new_versions = live.versions;
            new_versions.content += 1;

            ApplyResult::Applied(ProjectionDelta {
                new_aggregate: ItemAggregate::Live(LiveItemState {
                    snapshot: new_snapshot,
                    versions: new_versions,
                }),
                bumped_domains: vec![VersionDomain::Content],
                read_model_dirty: true,
                index_dirty: true,
            })
        }
    }
}

// ──────────────────────���──────────────────────────────────────────────────────
// Fork helpers
// ──────────────────────��──────────────────────────────────────────────────────

fn fork_from_text_edit(aggregate: &ItemAggregate, new_text: &str) -> ApplyResult {
    // Build a new snapshot from the edit content.
    let forked_snapshot = match aggregate {
        ItemAggregate::Live(live) => {
            let mut snap = live.snapshot.clone();
            snap.content_text = new_text.to_string();
            snap.content_hash = crate::models::StoredItem::hash_string(new_text);
            if let TypeSpecificData::Text { ref mut value } = snap.type_specific {
                *value = new_text.to_string();
            }
            snap.timestamp_unix = chrono::Utc::now().timestamp();
            snap
        }
        ItemAggregate::Tombstoned(tomb) => ItemSnapshotData {
            content_type: tomb.content_type.clone(),
            content_text: new_text.to_string(),
            content_hash: crate::models::StoredItem::hash_string(new_text),
            source_app: None,
            source_app_bundle_id: None,
            timestamp_unix: chrono::Utc::now().timestamp(),
            is_bookmarked: false,
            thumbnail_base64: None,
            color_rgba: None,
            type_specific: TypeSpecificData::Text {
                value: new_text.to_string(),
            },
        },
    };

    ApplyResult::Forked(ForkPlan {
        forked_snapshot,
        reason: "concurrent text edit conflict".to_string(),
    })
}
