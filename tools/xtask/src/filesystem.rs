//! Shared filesystem operations used by automation commands.

use std::fs;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};

/// Remove a file, symlink, or directory tree when it exists.
pub(crate) fn remove_if_exists(path: &Utf8Path) -> Result<()> {
    if !path.as_std_path().exists() && !path.as_std_path().is_symlink() {
        return Ok(());
    }
    if path.as_std_path().is_dir() && !path.as_std_path().is_symlink() {
        fs::remove_dir_all(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    } else {
        fs::remove_file(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    }
    Ok(())
}

/// Recursively merge a directory tree into `destination`, preserving symlinks.
/// Callers that need replacement semantics remove the destination first.
pub(crate) fn copy_directory(source: &Utf8Path, destination: &Utf8Path) -> Result<()> {
    if !source.as_std_path().is_dir() {
        return Err(anyhow!("source directory not found: {source}"));
    }
    fs::create_dir_all(destination.as_std_path())
        .with_context(|| format!("creating {destination}"))?;
    for entry in fs::read_dir(source.as_std_path()).with_context(|| format!("reading {source}"))? {
        let entry = entry?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|path| anyhow!("non-UTF-8 path: {path:?}"))?;
        let target = destination.join(path.file_name().unwrap());
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            let link_target = fs::read_link(path.as_std_path())
                .with_context(|| format!("reading symlink {path}"))?;
            std::os::unix::fs::symlink(&link_target, target.as_std_path())
                .with_context(|| format!("recreating symlink {target}"))?;
        } else if file_type.is_dir() {
            copy_directory(&path, &target)?;
        } else {
            fs::copy(path.as_std_path(), target.as_std_path())
                .with_context(|| format!("copying {path} to {target}"))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use camino::Utf8PathBuf;
    use tempfile::tempdir;

    use super::{copy_directory, remove_if_exists};

    #[test]
    fn removes_files_and_directories_and_ignores_missing_paths() {
        let temp = tempdir().unwrap();
        let root = Utf8PathBuf::from_path_buf(temp.path().to_path_buf()).unwrap();
        let file = root.join("file");
        let directory = root.join("directory");
        fs::write(file.as_std_path(), b"data").unwrap();
        fs::create_dir(directory.as_std_path()).unwrap();

        remove_if_exists(&file).unwrap();
        remove_if_exists(&directory).unwrap();
        remove_if_exists(&root.join("missing")).unwrap();

        assert!(!file.exists());
        assert!(!directory.exists());
    }

    #[test]
    fn copies_nested_directory_contents_and_preserves_symlinks() {
        let temp = tempdir().unwrap();
        let root = Utf8PathBuf::from_path_buf(temp.path().to_path_buf()).unwrap();
        let source = root.join("source");
        let destination = root.join("destination");
        fs::create_dir_all(source.join("nested").as_std_path()).unwrap();
        fs::create_dir_all(destination.as_std_path()).unwrap();
        fs::write(source.join("nested/file").as_std_path(), b"data").unwrap();
        fs::write(destination.join("existing").as_std_path(), b"keep").unwrap();
        std::os::unix::fs::symlink("nested/file", source.join("link").as_std_path()).unwrap();

        copy_directory(&source, &destination).unwrap();

        assert_eq!(fs::read(destination.join("nested/file")).unwrap(), b"data");
        assert_eq!(fs::read(destination.join("existing")).unwrap(), b"keep");
        assert_eq!(
            fs::read_link(destination.join("link")).unwrap(),
            std::path::PathBuf::from("nested/file")
        );
    }
}
