use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use connections::{BoardLayout, LayoutItem, Point, Rect, Size, Uuid};
use runtime::{AgentSession, LaunchSpec};

use crate::board_protocol::{now, only, BoardEvent, RunnerReport};
use crate::cards::{AgentRecord, RunnerSpec};
use crate::l10n::l;
use crate::orchestrator::{environment, is_inline_space, login_shell, Orchestrator, Turn};
use crate::process_inspector::{ProcessInspector, Sample};

/// How often running runners are measured.
const SAMPLE_INTERVAL: Duration = Duration::from_secs(2);

/// What runs once a runner has stopped.
pub(crate) type Stopped = Box<dyn FnOnce(&mut Turn) + Send>;

/// Runners: commands kept running in a terminal card (dev servers, watchers, workers), started
/// by the developer or by an agent through the runner tools. The core measures what each serves
/// (ports, with the network address when other devices can reach it) and costs (CPU, memory),
/// and stops it with everything it started.
impl Turn<'_> {
    /// Adds a runner card and starts it. An `owner` agent gets a line to it.
    pub(crate) fn add_runner(&mut self, command: &str, name: Option<&str>, directory: Option<String>, owner: Option<Uuid>, worktree: &str, origin: Point) -> AgentRecord {
        let trimmed = name.map_or("", |name| name.trim_matches(is_inline_space));
        let base = if trimmed.is_empty() { AgentRecord::runner_name(command) } else { trimmed.to_string() };
        let record = AgentRecord {
            runner: Some(RunnerSpec { command: command.to_string(), directory: directory.unwrap_or_else(|| worktree.to_string()), owner }),
            // Shown with the agent that started it.
            organization: owner.and_then(|owner| self.record(owner)?.organization),
            ..AgentRecord::new(Uuid::new(), worktree, AgentRecord::RUNNER_PROVIDER_ID, AgentRecord::unique_name(&base, self.cards_in(worktree)), Rect::at(origin, AgentRecord::RUNNER_SIZE))
        };
        self.insert(record.clone(), None);
        if let Some(owner) = owner {
            self.connect(owner, record.id);
        }
        self.start_runner(record.id);
        record
    }

    /// Starts a runner that isn't running.
    pub(crate) fn start_runner(&mut self, id: Uuid) {
        let Some(frame) = self.record(id).filter(|record| record.runner.is_some()).map(|record| record.frame) else { return };
        match self.session(id) {
            None => {
                self.server.open_session(crate::board_protocol::to_runtime(id), estimated_columns(frame), estimated_rows(frame), None);
                self.launch(id);
            }
            Some(session) if session.process_id().is_none() => self.launch(id),
            Some(_) => {}
        }
    }

    /// Stops a runner and everything it started; `completion` runs once it has exited.
    pub(crate) fn stop_runner(&mut self, id: Uuid, completion: Option<Stopped>) {
        // Still waiting for the PATH: stopping means never launching it.
        self.pending_launches.retain(|pending| *pending != id);
        let Some(session) = self.session(id) else {
            if let Some(completion) = completion {
                completion(self);
            }
            return;
        };
        let handle = self.handle.clone();
        session.terminate(
            3.0,
            // On the session's thread: back to the main loop.
            Some(Box::new(move || {
                handle.post(move |orchestrator: &mut Orchestrator, server| {
                    let mut turn = orchestrator.turn(server);
                    turn.clear_stats(id);
                    turn.runners_changed();
                    if let Some(completion) = completion {
                        completion(&mut turn);
                    }
                })
            })),
        );
    }

    /// Stops the runner if it runs and starts it again, with `command` instead when given.
    pub(crate) fn restart_runner(&mut self, id: Uuid, command: Option<String>) {
        if let Some(command) = command {
            self.update(id, None, |card| {
                if let Some(runner) = &mut card.runner {
                    runner.command = command;
                }
            });
        }
        self.stop_runner(id, Some(Box::new(move |turn: &mut Turn| turn.start_runner(id))));
    }

    /// Where a card of `size` an agent adds goes, connected to it: in the column right of its
    /// card, below the cards in the way (see `BoardLayout`).
    pub(crate) fn origin(&self, caller: &AgentRecord, size: Size) -> Point {
        BoardLayout::slot(size, Some(caller.id), &self.layout_items(&caller.worktree), self.bus.graph().connections(), BoardLayout::DEFAULT_ASPECT)
            .unwrap_or(Point::new(caller.frame.max_x() + BoardLayout::COLUMN_GAP, caller.frame.min_y()))
    }

    /// Everything on `worktree`'s canvas, as `BoardLayout` arranges it.
    fn layout_items(&self, worktree: &str) -> Vec<LayoutItem> {
        let other = |id, frame| LayoutItem { id, frame, is_hub: false };
        let cards = self.cards_in(worktree).map(|card| LayoutItem { id: card.id, frame: card.frame, is_hub: card.runner.is_none() });
        let post_its = self.post_its.iter().filter(|note| note.worktree == worktree).map(|note| other(note.id, note.frame));
        let images = self.images.iter().filter(|image| image.worktree == worktree).map(|image| other(image.id, image.frame));
        cards.chain(post_its).chain(images).chain(self.element_frames(worktree).map(|info| other(info.id, info.frame))).collect()
    }

    /// The addresses a runner serves, in port order: `localhost`, then the network address
    /// when the port is open to other devices.
    pub(crate) fn urls(&self, id: Uuid) -> Vec<(String, Option<String>)> {
        let ports = self.runner_stats.get(&id).map_or(&[][..], |stats| &stats.ports);
        ports.iter().map(|port| (format!("http://localhost:{}", port.port), self.network_address.as_ref().filter(|_| port.exposed).map(|address| format!("http://{address}:{}", port.port)))).collect()
    }

    /// The runner's latest output, scrollback included.
    pub(crate) fn output(&self, id: Uuid, lines: usize) -> Vec<String> {
        self.session(id).map(|session| session.with_terminal(|terminal| terminal.recent_text(lines))).unwrap_or_default()
    }

    // MARK: Internals

    pub(crate) fn launch_runner(&mut self, record: &AgentRecord, runner: &RunnerSpec, session: &AgentSession, search_path: &str) {
        if !Path::new(&runner.directory).exists() {
            return session.fail(l("This folder no longer exists on disk."));
        }
        // Markers of the core's own launcher (Claude Code) don't belong to the user's programs.
        let mut environment = environment();
        environment.retain(|key, _| !key.starts_with("CLAUDE_CODE") && key != "CLAUDECODE");
        let shell = login_shell(&environment);
        environment.insert("PATH".into(), search_path.to_string());
        environment.insert("TERM".into(), "xterm-256color".into());
        environment.insert("COLORTERM".into(), "truecolor".into());
        environment.entry("LANG".into()).or_insert_with(|| "en_US.UTF-8".into());
        // As for agents: a runner running `./run` must not reach this core.
        environment.retain(|key, _| !key.starts_with("AGENTBOARD_"));
        if self.runner_starts.contains_key(&record.id) {
            // Ran before: mark where the new run's output begins.
            session.annotate(&format!("\x1b[2m── {} ──\x1b[0m\r\n", l("restarted")), true);
        }
        // What the last run served and cost no longer applies.
        self.clear_stats(record.id);
        self.runner_starts.insert(record.id, now());
        let arguments = if runner.is_shell() { vec!["-l".to_string(), "-i".to_string()] } else { vec!["-l".to_string(), "-c".to_string(), runner.command.clone()] };
        session.start(crate::sandbox::wrap(LaunchSpec { executable: shell, arguments, environment, directory: runner.directory.clone() }, &record.worktree, &self.data_folder));
        self.start_monitoring();
        self.runners_changed();
    }

    pub(crate) fn forget_runner(&mut self, id: Uuid) {
        self.clear_stats(id);
        self.runner_starts.remove(&id);
        self.runners_changed();
    }

    fn clear_stats(&mut self, id: Uuid) {
        self.runner_stats.remove(&id);
        self.runner_samples.remove(&id);
    }

    /// Tells the boards what the runners serve and cost, when that changed.
    pub(crate) fn runners_changed(&mut self) {
        let report = RunnerReport { stats: self.runner_stats.clone(), starts: self.runner_starts.clone(), network_address: self.network_address.clone() };
        if report != self.reported_runners {
            self.reported_runners = report.clone();
            self.broadcast(&BoardEvent::Runners(only(report)), None);
        }
    }

    /// Measures running runners every few seconds; stops once none runs.
    fn start_monitoring(&mut self) {
        if self.runner_monitor.is_some() {
            return;
        }
        self.network_address = ProcessInspector::network_address();
        self.monitors_started += 1;
        self.runner_monitor = Some(self.monitors_started);
        self.schedule_sample(self.monitors_started);
        // A server takes a moment to open its port: look once soon, not only after the interval.
        self.handle.post_after(Duration::from_millis(500), |orchestrator: &mut Orchestrator, server| orchestrator.turn(server).sample_runners());
    }

    fn schedule_sample(&mut self, monitor: u64) {
        self.handle.post_after(SAMPLE_INTERVAL, move |orchestrator: &mut Orchestrator, server| {
            let mut turn = orchestrator.turn(server);
            // A monitor stopped since (and maybe started again) has a timer of its own.
            if turn.runner_monitor == Some(monitor) {
                turn.sample_runners();
                if turn.runner_monitor == Some(monitor) {
                    turn.schedule_sample(monitor);
                }
            }
        });
    }

    pub(crate) fn sample_runners(&mut self) {
        let roots: HashMap<Uuid, i32> = self.cards.iter().filter(|record| record.runner.is_some()).filter_map(|record| Some((record.id, self.session(record.id)?.process_id()?))).collect();
        if roots.is_empty() {
            self.runner_monitor = None;
            if !self.runner_stats.is_empty() || !self.runner_samples.is_empty() {
                self.runner_stats.clear();
                self.runner_samples.clear();
                self.runners_changed();
            }
            return;
        }
        // One measurement at a time: a slow one must not pile more up behind it.
        if std::mem::replace(&mut self.sampling, true) {
            return;
        }
        let (previous, handle) = (self.runner_samples.clone(), self.handle.clone());
        // Off the main loop: it walks the user's processes.
        std::thread::spawn(move || {
            let (samples, address) = (ProcessInspector::sample(&roots, &previous), ProcessInspector::network_address());
            handle.post(move |orchestrator: &mut Orchestrator, server| orchestrator.turn(server).sampled(samples, address, &roots));
        });
    }

    fn sampled(&mut self, mut samples: HashMap<Uuid, Sample>, address: Option<String>, roots: &HashMap<Uuid, i32>) {
        self.sampling = false;
        // Runners that stopped while being measured drop out.
        samples.retain(|id, _| self.session(*id).and_then(|session| session.process_id()) == roots.get(id).copied());
        self.runner_stats = samples.iter().map(|(id, sample)| (*id, sample.stats.clone())).collect();
        self.runner_samples = samples;
        self.network_address = address;
        self.runners_changed();
    }
}

/// Terminal size before a board has measured the card: close enough for a program to start.
fn estimated_columns(frame: Rect) -> usize {
    (((frame.width() - 24.0) / 7.2) as i64).max(20) as usize
}

fn estimated_rows(frame: Rect) -> usize {
    (((frame.height() - 80.0) / 15.0) as i64).max(4) as usize
}
