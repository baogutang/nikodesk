use super::*;
use base::fs::directory_scan::{Completion, Kind, Output};

impl<T: InvokeUiCM> IpcTaskRunner<T> {
    pub(super) fn nikodesk_directory_allowed(&self) -> bool {
        CLIENTS
            .read()
            .ok()
            .and_then(|clients| {
                clients.get(&self.conn_id).map(|client| {
                    client.authorized
                        && !client.disconnected
                        && client.file
                        && client.is_file_transfer
                        && client.tx.same_channel(&self.tx)
                })
            })
            .unwrap_or(false)
    }

    pub(super) fn handle_nikodesk_directory_request(&mut self, operation: &ipc::FS) -> bool {
        match operation {
            ipc::FS::NikoScanDirectory { request, conn_id } => {
                let result = if *conn_id != self.conn_id || !self.nikodesk_directory_allowed() {
                    Err("Permission denied".to_owned())
                } else if request.kind == Kind::Files
                    && self.read_jobs.iter().any(|job| job.id() == request.id)
                {
                    Err("A file read with this id is already running".to_owned())
                } else {
                    self.niko_directory
                        .start(request.clone(), get_max_validated_files())
                };
                if let Err(error) = result {
                    let _ = self.tx.send(Data::NikoDirectoryResult {
                        request: request.clone(),
                        conn_id: *conn_id,
                        result: Err(error),
                    });
                }
                true
            }
            ipc::FS::NikoCancelDirectory { request, conn_id } => {
                if *conn_id == self.conn_id {
                    self.niko_directory.cancel_matching(request);
                }
                true
            }
            ipc::FS::ReadDir { .. } => {
                send_raw(
                    fs::new_error(
                        0,
                        "Restart both NikoDesk processes to browse directories",
                        -1,
                    ),
                    &self.tx,
                );
                true
            }
            ipc::FS::ReadEmptyDirs { .. } => {
                send_raw(
                    fs::new_error(-1, "NIKODESK_EMPTY_DIRECTORY_READ_FAILED", -1),
                    &self.tx,
                );
                true
            }
            ipc::FS::CancelRead { id, conn_id } if *conn_id == self.conn_id => {
                self.niko_directory.cancel(*id);
                false
            }
            // Do not silently return to an uncancellable walker when a still-running
            // older backend is connected to the updated CM.
            ipc::FS::ReadAllFiles {
                id, conn_id, path, ..
            } => {
                let _ = self.tx.send(Data::AllFilesResult {
                    id: *id,
                    conn_id: *conn_id,
                    path: path.clone(),
                    result: Err("Restart both NikoDesk processes to use file transfer".into()),
                });
                true
            }
            ipc::FS::ReadFile {
                id,
                conn_id,
                file_num,
                include_hidden,
                ..
            } => {
                let _ = self.tx.send(Data::ReadJobInitResult {
                    id: *id,
                    conn_id: *conn_id,
                    file_num: *file_num,
                    include_hidden: *include_hidden,
                    result: Err("Restart both NikoDesk processes to use file transfer".into()),
                });
                true
            }
            _ => false,
        }
    }

    pub(super) fn poll_nikodesk_directory(&mut self) {
        if !self.nikodesk_directory_allowed() {
            self.niko_directory.cancel_all();
            return;
        }
        while let Some(Completion { request, result }) = self.niko_directory.take_ready() {
            let result = result.and_then(|output| {
                let files = match output {
                    Output::Response(response) => {
                        return response.write_to_bytes().map_err(|e| e.to_string())
                    }
                    Output::Files(files) => files,
                };
                let job = if request.read.is_some() {
                    Some(
                        fs::directory_scan::read_job(&request, files.clone())
                            .map_err(|e| e.to_string())?,
                    )
                } else {
                    None
                };
                let directory = FileDirectory {
                    id: request.id,
                    path: request.path.clone(),
                    entries: files,
                    ..Default::default()
                };
                let bytes = directory.write_to_bytes().map_err(|e| e.to_string())?;
                if let Some(mut job) = job {
                    job.conn_id = self.conn_id;
                    self.read_jobs.push(job);
                }
                Ok(bytes)
            });
            let _ = self.tx.send(Data::NikoDirectoryResult {
                request,
                conn_id: self.conn_id,
                result,
            });
        }
    }
}
