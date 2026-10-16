//! The app's service must not outlive the pipe owned by its GUI parent.
use fsearch::{index::Index, walk::Listing};
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

struct Fixture {
    root: PathBuf,
    _lock: File,
    child: Option<Child>,
}

impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(format!("/tmp/fsg-{}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed), fsearch::query::now_secs()));
        let dir = root.join("Library/Application Support/FSearch");
        std::fs::create_dir_all(&dir).unwrap();
        // Keep this lifecycle test from starting a real whole-disk crawl.
        let lock = File::create(dir.join("daemon.lock")).unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        Index::build(vec![Listing::default()], 1, fsearch::query::now_secs(), root.to_str().unwrap().as_bytes())
            .save(&dir.join("index.bin")).unwrap();
        Self { root, _lock: lock, child: None }
    }

    fn command(&self, op: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_fsearch"));
        command.arg(op).env("HOME", &self.root).env("MallocSpaceEfficient", "1")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        command
    }
    fn start(&mut self) {
        self.child = Some(self.command("serve-gui").spawn().unwrap());
        let child = self.child.as_mut().unwrap();
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        // Bound even startup failures, rather than blocking forever on a regression.
        let mut fd = libc::pollfd { fd: stdout.get_ref().as_raw_fd(), events: libc::POLLIN, revents: 0 };
        assert!(unsafe { libc::poll(&mut fd, 1, 10_000) } > 0);
        stdout.read_line(&mut ready).unwrap();
        assert_eq!(ready.trim(), "ready");
    }

    fn query(&self, request: &str) -> serde_json::Value {
        let mut bridge = self.command("stdio-gui").spawn().unwrap();
        writeln!(bridge.stdin.as_mut().unwrap(), "{request}").unwrap();
        drop(bridge.stdin.take());
        let output = bridge.wait_with_output().unwrap();
        assert!(output.status.success());
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child { let _ = child.kill(); let _ = child.wait(); }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn gui_service_exits_on_parent_eof_and_bridge_never_respawns_it() {
    let mut fixture = Fixture::new();
    fixture.start();

    let mut bridge = fixture.command("stdio-gui").spawn().unwrap();
    writeln!(bridge.stdin.as_mut().unwrap(), "{{\"op\":\"ping\"}}").unwrap();
    drop(bridge.stdin.take());
    let reply = bridge.wait_with_output().unwrap();
    assert!(reply.status.success());
    let reply: serde_json::Value = serde_json::from_slice(&reply.stdout).unwrap();
    assert_eq!(reply["ok"], true);

    let status = fixture.query(r#"{"op":"status","progress":true}"#);
    assert_eq!(status["ok"], true);
    assert!(status["ready"].is_boolean());
    assert!(status["content_ready"].is_boolean());
    assert!(status["replaying"].is_boolean());
    assert_eq!(status["owner"], false);

    let child = fixture.child.as_mut().unwrap();
    assert!(child.try_wait().unwrap().is_none(), "bridge exit must not stop the service");
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "service outlived its parent's stdin");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(fixture.root.join("Library/Application Support/FSearch/index.bin").exists());
    let output = fixture.command("stdio-gui").output().unwrap();
    assert!(!output.status.success(), "connect-only bridge must not spawn a detached daemon");
    assert!(!fixture.root.join("Library/Application Support/FSearch/socket.lock").exists());
}

#[test]
fn progress_status_is_available_before_initial_index_exists() {
    let mut fixture = Fixture::new();
    std::fs::remove_file(fixture.root.join("Library/Application Support/FSearch/index.bin")).unwrap();
    // The held writer lock keeps the service in its initial waiting state.
    fixture.start();
    let status = fixture.query(r#"{"op":"status","progress":true}"#);
    assert_eq!(status["ok"], true);
    assert_eq!(status["ready"], false);
    assert_eq!(status["entries"], 0);
    assert_eq!(status["listed"], 0);
    let legacy = fixture.query(r#"{"op":"status"}"#);
    assert_eq!(legacy["ok"], false);
    assert!(legacy["error"].as_str().unwrap().starts_with("indexing:"));
}

#[test]
fn embedded_engine_needs_no_service_or_socket_and_exits_on_eof() {
    let mut fixture = Fixture::new();
    // Even an occupied legacy GUI lock must not prevent the app's engine.
    let gui_lock = File::create(fixture.root.join("Library/Application Support/FSearch/gui.lock")).unwrap();
    assert_eq!(unsafe { libc::flock(gui_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    fixture.child = Some(fixture.command("embedded-gui").spawn().unwrap());
    let child = fixture.child.as_mut().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    for request in [r#"{"op":"ping"}"#, r#"{"op":"status","progress":true}"#, "invalid", r#"{"op":"ping"}"#] {
        writeln!(child.stdin.as_mut().unwrap(), "{request}").unwrap();
        let mut fd = libc::pollfd { fd: output.get_ref().as_raw_fd(), events: libc::POLLIN, revents: 0 };
        assert!(unsafe { libc::poll(&mut fd, 1, 10_000) } > 0);
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["ok"], request != "invalid");
    }
    assert!(!fixture.root.join("Library/Application Support/FSearch/gui.sock").exists());
    assert!(!fixture.root.join("Library/Application Support/FSearch/fsearch.sock").exists());
    assert!(!fixture.root.join("Library/Application Support/FSearch/socket.lock").exists());
    // Another copy can run concurrently without a shared service lock.
    let mut second = fixture.command("embedded-gui").spawn().unwrap();
    writeln!(second.stdin.as_mut().unwrap(), "{{\"op\":\"ping\"}}").unwrap();
    drop(second.stdin.take());
    let reply = second.wait_with_output().unwrap();
    assert!(reply.status.success());
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&reply.stdout).unwrap()["ok"], true);
    let child = fixture.child.as_mut().unwrap();
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "embedded engine outlived its app pipe");
        std::thread::sleep(Duration::from_millis(10));
    }
}
