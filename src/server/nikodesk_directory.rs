use super::*;
use base::fs::directory_scan::{self, Completion, Kind, Output, ReadSpec, Request};

impl Connection {
    fn nikodesk_directory_allowed(&self) -> bool {
        self.authorized
            && !self.closed
            && self.file
            && self.file_transfer.is_some()
            && Self::permission(keys::OPTION_ENABLE_FILE_TRANSFER, &self.control_permissions)
    }

    pub(super) async fn start_nikodesk_directory(
        &mut self,
        id: i32,
        path: String,
        include_hidden: bool,
        read: Option<ReadSpec>,
    ) {
        if !self.nikodesk_directory_allowed() {
            self.send(fs::new_error(id, "Permission denied", -1)).await;
            return;
        }
        if self.cm_read_job_ids.contains(&id) || self.read_jobs.iter().any(|j| j.id() == id) {
            self.send(fs::new_error(
                id,
                "A file read with this id is already running",
                -1,
            ))
            .await;
            return;
        }
        let request = Request::new(id, path, include_hidden, read);
        let result = if crate::common::need_fs_cm_send_files() {
            self.niko_directory.track(request.clone()).map(|_| {
                self.send_fs(ipc::FS::NikoScanDirectory {
                    request,
                    conn_id: self.inner.id(),
                });
            })
        } else {
            self.niko_directory
                .start(request, crate::ui_cm_interface::get_max_validated_files())
        };
        if let Err(error) = result {
            self.send(fs::new_error(id, error, -1)).await;
        }
        if self.niko_directory.is_pending() {
            self.file_timer = crate::rustdesk_interval(time::interval(Duration::from_millis(5)));
        }
    }

    pub(super) fn start_nikodesk_directory_query(
        &mut self,
        path: &str,
        include_hidden: bool,
        kind: Kind,
    ) {
        let mut request = Request::new(
            if kind == Kind::EmptyDirectories {
                -1
            } else {
                0
            },
            path.to_owned(),
            include_hidden,
            None,
        );
        request.kind = kind;
        if !self.nikodesk_directory_allowed()
            || !crate::common::is_peer_path_allowed(path, kind == Kind::Directory)
        {
            self.inner
                .send(directory_scan::error(&request, "Permission denied").into());
            return;
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let result = self.niko_directory.track(request.clone()).map(|_| {
            self.send_fs(ipc::FS::NikoScanDirectory {
                request: request.clone(),
                conn_id: self.inner.id(),
            });
        });
        #[cfg(any(target_os = "android", target_os = "ios"))]
        let result = self.niko_directory.start(
            request.clone(),
            crate::ui_cm_interface::get_max_validated_files(),
        );
        if let Err(error) = result {
            self.inner
                .send(directory_scan::error(&request, error).into());
        }
        if self.niko_directory.is_pending() {
            self.file_timer = crate::rustdesk_interval(time::interval(Duration::from_millis(5)));
        }
    }

    pub(super) fn cancel_nikodesk_directories(&mut self) {
        let requests: Vec<_> = self.niko_directory.requests().cloned().collect();
        self.niko_directory.cancel_all();
        for request in requests {
            self.send_fs(ipc::FS::NikoCancelDirectory {
                request,
                conn_id: self.inner.id(),
            });
        }
    }

    fn revoke_nikodesk_directory_reads(&mut self) {
        self.cancel_nikodesk_directories();
        if self.file_transfer.is_some() {
            self.read_jobs.clear();
            let ids: Vec<_> = self.cm_read_job_ids.drain().collect();
            for id in ids {
                self.send_fs(ipc::FS::CancelRead {
                    id,
                    conn_id: self.inner.id(),
                });
            }
        }
    }

    pub(super) async fn poll_nikodesk_directory(&mut self) {
        if !self.nikodesk_directory_allowed() {
            self.revoke_nikodesk_directory_reads();
            return;
        }
        while let Some(Completion { request, result }) = self.niko_directory.take_ready() {
            if !self.nikodesk_directory_allowed() {
                self.revoke_nikodesk_directory_reads();
                return;
            }
            // External requests only yield here when their deadline expires.
            if crate::common::need_fs_cm_send_files()
                || (request.kind != Kind::Files
                    && !cfg!(any(target_os = "android", target_os = "ios")))
            {
                self.send_fs(ipc::FS::NikoCancelDirectory {
                    request: request.clone(),
                    conn_id: self.inner.id(),
                });
            }
            match result {
                Err(error) => self.send(directory_scan::error(&request, error)).await,
                Ok(Output::Files(files)) if request.read.is_some() => {
                    match directory_scan::read_job(&request, files) {
                        Ok(job) => self.process_new_read_job(job, request.path).await,
                        Err(error) => self.send(directory_scan::error(&request, error)).await,
                    }
                }
                Ok(Output::Response(message)) => self.send(message).await,
                Ok(Output::Files(files)) => {
                    self.send(fs::new_dir(request.id, request.path, files))
                        .await
                }
            }
        }
    }

    pub(super) async fn receive_nikodesk_directory(
        &mut self,
        request: Request,
        conn_id: i32,
        result: Result<Vec<u8>, String>,
    ) {
        if conn_id != self.inner.id()
            || !self.nikodesk_directory_allowed()
            || !self.niko_directory.finish(&request)
        {
            return;
        }
        if request.kind != Kind::Files {
            let response = match result {
                Ok(bytes) => Message::parse_from_bytes(&bytes).unwrap_or_else(|_| {
                    directory_scan::error(&request, "Invalid directory response")
                }),
                Err(error) => directory_scan::error(&request, error),
            };
            self.send(response).await;
        } else if let Some(read) = request.read {
            // Register only after the matching scan result: queued blocks from a
            // cancelled job with a reused id precede this result and are ignored.
            self.cm_read_job_ids.insert(request.id);
            self.handle_read_job_init_result(
                request.id,
                read.file_num,
                request.include_hidden,
                result,
            )
            .await;
        } else {
            self.handle_all_files_result(request.id, request.path, result)
                .await;
        }
    }
}
