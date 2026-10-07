use super::*;

pub(super) fn scan_query(
    request: &Request,
    cancelled: &AtomicBool,
    started: Instant,
) -> ResultType<Message> {
    let path = if request.path.is_empty() {
        Config::get_home()
    } else {
        PathBuf::from(&request.path)
    };
    let mut budget = Budget {
        cancelled,
        started,
        limits: Limits::default(),
        entries: 0,
        names: 0,
        max_files: MAX_ENTRIES,
    };
    budget.check()?;
    let mut response = FileResponse::new();
    match request.kind {
        Kind::Directory => response.set_dir(list(&path, request.include_hidden, &mut budget)?),
        Kind::EmptyDirectories => {
            validate_fs_path_argument(&request.path, "empty-directory source")?;
            response.set_empty_dirs(ReadEmptyDirsResponse {
                path: request.path.clone(),
                empty_dirs: empty(&path, request.include_hidden, &mut budget)?,
                ..Default::default()
            });
        }
        Kind::Files => bail!("Unexpected directory query"),
    }
    budget.check()?;
    let mut message = Message::new();
    message.set_file_response(response);
    Ok(message)
}

fn hidden(name: &str, _meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        _meta.file_attributes() & 0x2 != 0
    }
    #[cfg(not(windows))]
    {
        name.starts_with('.')
    }
}

fn list(path: &Path, include_hidden: bool, budget: &mut Budget<'_>) -> ResultType<FileDirectory> {
    #[cfg(windows)]
    if path == Path::new("/") {
        // The virtual drive list has at most 32 entries and performs no directory walk.
        return read_dir(path, include_hidden);
    }
    let mut directory = FileDirectory {
        path: get_string(path),
        ..Default::default()
    };
    for entry in path.read_dir()? {
        budget.entry()?;
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow!("Directory contains a non-UTF-8 file name"))?;
        let meta = std::fs::symlink_metadata(entry.path())?;
        budget.check()?;
        let is_hidden = hidden(&name, &meta);
        if is_hidden && !include_hidden {
            continue;
        }
        let is_link = meta.file_type().is_symlink();
        let is_dir = if is_link {
            entry.path().is_dir()
        } else {
            meta.is_dir()
        };
        let entry_type = match (is_dir, is_link) {
            (true, true) => FileType::DirLink,
            (false, true) => FileType::FileLink,
            (true, false) => FileType::Dir,
            _ => FileType::File,
        };
        budget.push(&mut directory.entries, name, meta, is_hidden)?;
        if let Some(last) = directory.entries.last_mut() {
            last.entry_type = entry_type.into();
            if is_dir || is_link {
                last.size = 0;
            }
        }
    }
    budget.check()?;
    Ok(directory)
}

fn empty(
    path: &Path,
    include_hidden: bool,
    budget: &mut Budget<'_>,
) -> ResultType<Vec<FileDirectory>> {
    let meta = std::fs::symlink_metadata(path)?;
    budget.check()?;
    if meta.file_type().is_symlink() {
        bail!("Symbolic-link scan roots are not supported");
    }
    if meta.is_file() {
        return Ok(Vec::new());
    }
    let mut directories = Vec::new();
    let mut stack = vec![(path.read_dir()?, path.to_path_buf(), 0usize, true)];
    while let Some((entries, current, depth, is_empty)) = stack.last_mut() {
        budget.check()?;
        let entry = match entries.next() {
            Some(entry) => entry?,
            None => {
                if *is_empty {
                    if directories.len() >= 4096 {
                        bail!("Too many empty directories");
                    }
                    let name = get_string(current);
                    budget.names = budget.names.saturating_add(name.len());
                    if budget.names > budget.limits.names {
                        bail!("Directory scan name-size limit exceeded");
                    }
                    directories.push(FileDirectory {
                        path: name,
                        ..Default::default()
                    });
                }
                stack.pop();
                continue;
            }
        };
        budget.entry()?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow!("Directory contains a non-UTF-8 file name"))?;
        let meta = std::fs::symlink_metadata(entry.path())?;
        budget.check()?;
        if hidden(&name, &meta) && !include_hidden {
            continue;
        }
        *is_empty = false;
        if meta.is_dir() && !meta.file_type().is_symlink() {
            let next_depth = *depth + 1;
            if next_depth > budget.limits.depth {
                bail!("Directory scan depth limit exceeded");
            }
            let next = entry.path().read_dir()?;
            budget.check()?;
            stack.push((next, entry.path(), next_depth, true));
        }
    }
    budget.check()?;
    Ok(directories)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regular_and_empty_queries_keep_protocol_shape_and_bounds() {
        let fixture = super::super::tests::Fixture::new();
        fixture.file("file.txt");
        std::fs::create_dir(fixture.0.join("empty")).unwrap();
        std::fs::create_dir(fixture.0.join("hidden-only")).unwrap();
        fixture.file("hidden-only/.hidden");
        let mut request = Request::new(0, fixture.0.to_str().unwrap().into(), false, None);
        request.kind = Kind::Directory;
        let response = scan_query(&request, &AtomicBool::new(false), Instant::now()).unwrap();
        assert_eq!(response.file_response().dir().entries.len(), 3);
        request.kind = Kind::EmptyDirectories;
        let response = scan_query(&request, &AtomicBool::new(false), Instant::now()).unwrap();
        assert_eq!(response.file_response().empty_dirs().empty_dirs.len(), 2);
        request.include_hidden = true;
        let response = scan_query(&request, &AtomicBool::new(false), Instant::now()).unwrap();
        assert_eq!(response.file_response().empty_dirs().empty_dirs.len(), 1);
        let cancelled = AtomicBool::new(false);
        let mut budget = Budget {
            cancelled: &cancelled,
            started: Instant::now(),
            limits: Limits {
                entries: 1,
                ..Limits::default()
            },
            entries: 0,
            names: 0,
            max_files: MAX_ENTRIES,
        };
        assert!(list(&fixture.0, true, &mut budget).is_err());
        budget.entries = 0;
        assert!(empty(&fixture.0, true, &mut budget).is_err());
    }
}
