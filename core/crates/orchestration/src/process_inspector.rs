use std::collections::{HashMap, HashSet};
use std::net::Ipv4Addr;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use connections::Uuid;

/// A TCP port a runner's processes listen on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ListeningPort {
    pub port: i64,
    /// Listens on every interface, so other devices on the network reach it too (not only this machine).
    pub exposed: bool,
}

/// What a runner costs and serves right now, summed over its process and everything it started.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunnerStats {
    /// Percent of one core over the last sample interval; none until two samples exist.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu: Option<f64>,
    /// Bytes of memory: resident set on Linux, physical footprint on macOS.
    pub memory: u64,
    pub processes: i64,
    pub ports: Vec<ListeningPort>,
}

/// Reads processes without spawning `ps`: a process's descendants, their CPU time and memory,
/// and the TCP ports they listen on. From `/proc` on Linux; on macOS through libproc. Only the
/// user's own processes are looked at, which is all a runner starts.
pub struct ProcessInspector;

/// A measurement of one runner: its stats, and the CPU time it had used, for the next sample.
#[derive(Clone, Debug)]
pub struct Sample {
    pub stats: RunnerStats,
    /// Nanoseconds.
    cpu_time: u64,
    time: Instant,
}

impl ProcessInspector {
    /// Measures each root process and its descendants. `previous` gives each its last sample, to
    /// turn CPU time into a percentage. Walks every process of the user: call it off the main loop.
    pub fn sample(roots: &HashMap<Uuid, i32>, previous: &HashMap<Uuid, Sample>) -> HashMap<Uuid, Sample> {
        if roots.is_empty() {
            return HashMap::new();
        }
        let children = system::children_by_parent();
        let now = Instant::now();
        let trees: HashMap<Uuid, Vec<i32>> = roots.iter().map(|(id, root)| (*id, Self::descendants(*root, &children))).collect();
        let all: Vec<i32> = trees.values().flatten().copied().collect();
        let listening = system::listening_ports(&all);
        trees
            .into_iter()
            .map(|(id, tree)| {
                let (mut cpu_time, mut memory) = (0u64, 0u64);
                let mut ports: HashMap<i64, bool> = HashMap::new();
                for pid in &tree {
                    if let Some((cpu, resident)) = system::usage(*pid) {
                        cpu_time += cpu;
                        memory += resident;
                    }
                    // A port on both IPv4 and IPv6 shows once, exposed if either is.
                    for port in listening.get(pid).into_iter().flatten() {
                        *ports.entry(port.port).or_default() |= port.exposed;
                    }
                }
                let cpu = previous.get(&id).filter(|last| now > last.time && cpu_time >= last.cpu_time).map(|last| (cpu_time - last.cpu_time) as f64 / (now - last.time).as_nanos() as f64 * 100.0);
                let mut ports: Vec<ListeningPort> = ports.into_iter().map(|(port, exposed)| ListeningPort { port, exposed }).collect();
                ports.sort();
                (id, Sample { stats: RunnerStats { cpu, memory, processes: tree.len() as i64, ports }, cpu_time, time: now })
            })
            .collect()
    }

    /// `root` and every process below it.
    fn descendants(root: i32, children: &HashMap<i32, Vec<i32>>) -> Vec<i32> {
        let mut result = vec![root];
        let mut seen: HashSet<i32> = HashSet::from([root]);
        let mut index = 0;
        while index < result.len() {
            for child in children.get(&result[index]).into_iter().flatten() {
                if seen.insert(*child) {
                    result.push(*child);
                }
            }
            index += 1;
        }
        result
    }

    /// This machine's address on the local network, for ports other devices can reach: the
    /// first IPv4 address of an interface that is up and isn't loopback (`en0` first on a Mac,
    /// and never a container bridge).
    pub fn network_address() -> Option<String> {
        let mut candidates: Vec<(String, String)> = Vec::new();
        // SAFETY: getifaddrs fills a list freed below; each entry is read while the list lives,
        // and an address is read as sockaddr_in only when its family says it is one.
        unsafe {
            let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
            if libc::getifaddrs(&mut list) != 0 {
                return None;
            }
            let mut entry = list;
            while !entry.is_null() {
                let interface = &*entry;
                entry = interface.ifa_next;
                let up = interface.ifa_flags & libc::IFF_UP as u32 != 0 && interface.ifa_flags & libc::IFF_LOOPBACK as u32 == 0;
                if !up || interface.ifa_addr.is_null() || (*interface.ifa_addr).sa_family as i32 != libc::AF_INET {
                    continue;
                }
                let address = (*(interface.ifa_addr as *const libc::sockaddr_in)).sin_addr.s_addr;
                let name = std::ffi::CStr::from_ptr(interface.ifa_name).to_string_lossy().into_owned();
                candidates.push((name, Ipv4Addr::from(u32::from_be(address)).to_string()));
            }
            libc::freeifaddrs(list);
        }
        if cfg!(target_os = "macos") {
            candidates.retain(|(name, _)| name.starts_with("en"));
            // en0 is the built-in Wi-Fi (or Ethernet) on every Mac.
            candidates.sort_by_key(|(name, _)| name != "en0");
        } else {
            candidates.retain(|(name, _)| !["docker", "br-", "veth", "virbr", "cni", "flannel", "tun", "tap"].iter().any(|prefix| name.starts_with(prefix)));
        }
        candidates.into_iter().next().map(|(_, address)| address)
    }
}

#[cfg(target_os = "linux")]
mod system {
    use std::collections::{HashMap, HashSet};
    use std::os::unix::fs::MetadataExt;

    use super::ListeningPort;

    /// Parent, CPU ticks and resident pages of `pid`, from `/proc/<pid>/stat`.
    fn stat(pid: i32) -> Option<(i32, u64, u64)> {
        let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // The name, in parentheses, may hold spaces and parentheses of its own.
        let fields: Vec<&str> = text.get(text.rfind(')')? + 1..)?.split_ascii_whitespace().collect();
        // From the state (field 3): parent is 4, utime 14, stime 15, rss 24.
        Some((fields.get(1)?.parse().ok()?, fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?, fields.get(21)?.parse().ok()?))
    }

    /// The user's processes by parent.
    pub fn children_by_parent() -> HashMap<i32, Vec<i32>> {
        // SAFETY: getuid only reads the process's credentials.
        let user = unsafe { libc::getuid() };
        let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
        for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
            let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<i32>().ok()) else { continue };
            if entry.metadata().is_ok_and(|metadata| metadata.uid() == user) {
                if let Some((parent, _, _)) = stat(pid) {
                    children.entry(parent).or_default().push(pid);
                }
            }
        }
        children
    }

    /// CPU time used (nanoseconds) and resident memory (bytes).
    pub fn usage(pid: i32) -> Option<(u64, u64)> {
        let (_, ticks, pages) = stat(pid)?;
        // SAFETY: sysconf only reads system constants.
        let (per_second, page) = unsafe { (libc::sysconf(libc::_SC_CLK_TCK).max(1) as u64, libc::sysconf(libc::_SC_PAGESIZE).max(1) as u64) };
        Some((ticks * 1_000_000_000 / per_second, pages * page))
    }

    /// The TCP ports each of `pids` listens on: its sockets (`/proc/<pid>/fd`) among the
    /// listening ones of `/proc/net/tcp` and `tcp6`.
    pub fn listening_ports(pids: &[i32]) -> HashMap<i32, Vec<ListeningPort>> {
        let mut listening: HashMap<u64, ListeningPort> = HashMap::new();
        for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
            for line in std::fs::read_to_string(table).unwrap_or_default().lines().skip(1) {
                let fields: Vec<&str> = line.split_ascii_whitespace().collect();
                let (Some(local), Some(&"0A"), Some(inode)) = (fields.get(1), fields.get(3), fields.get(9).and_then(|inode| inode.parse::<u64>().ok())) else { continue };
                let Some((address, port)) = local.rsplit_once(':') else { continue };
                let Ok(port) = i64::from_str_radix(port, 16) else { continue };
                if port > 0 {
                    listening.insert(inode, ListeningPort { port, exposed: !is_loopback(address) });
                }
            }
        }
        let mut result = HashMap::new();
        if listening.is_empty() {
            return result;
        }
        for pid in pids {
            let mut seen = HashSet::new();
            for entry in std::fs::read_dir(format!("/proc/{pid}/fd")).into_iter().flatten().flatten() {
                let Ok(target) = std::fs::read_link(entry.path()) else { continue };
                let inode = target.to_str().and_then(|target| target.strip_prefix("socket:[")?.strip_suffix(']')?.parse::<u64>().ok());
                if let Some(port) = inode.and_then(|inode| listening.get(&inode)).filter(|port| seen.insert(**port)) {
                    result.entry(*pid).or_insert_with(Vec::new).push(*port);
                }
            }
        }
        result
    }

    /// An address as `/proc/net/tcp` prints it: each 32-bit word of the network-order bytes in
    /// hex, as this machine reads it.
    fn is_loopback(address: &str) -> bool {
        let words: Vec<[u8; 4]> = address.as_bytes().chunks(8).filter_map(|word| u32::from_str_radix(std::str::from_utf8(word).ok()?, 16).ok()).map(u32::to_ne_bytes).collect();
        match words.as_slice() {
            [v4] => v4[0] == 127,
            // ::1, and 127.0.0.0/8 mapped into IPv6.
            [a, b, c, d] => (*a == [0; 4] && *b == [0; 4]) && ((*c == [0; 4] && *d == [0, 0, 0, 1]) || (*c == [0, 0, 0xFF, 0xFF] && d[0] == 127)),
            _ => false,
        }
    }

    #[cfg(test)]
    #[test]
    fn loopback_addresses_are_told_apart() {
        if cfg!(target_endian = "little") {
            assert!(is_loopback("0100007F"));
            assert!(!is_loopback("00000000"));
            assert!(is_loopback("00000000000000000000000001000000"));
            assert!(is_loopback("0000000000000000FFFF00000100007F"));
            assert!(!is_loopback("00000000000000000000000000000000"));
        }
    }
}

#[cfg(target_os = "macos")]
mod system {
    use std::collections::HashMap;

    use super::ListeningPort;

    /// The user's processes by parent.
    pub fn children_by_parent() -> HashMap<i32, Vec<i32>> {
        let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
        // SAFETY: every call is given a buffer of the size it is told, and reads no more than it filled.
        unsafe {
            let user = libc::getuid();
            // Processes may start between the two calls.
            let capacity = libc::proc_listallpids(std::ptr::null_mut(), 0).max(0) as usize + 64;
            let mut pids = vec![0i32; capacity];
            let count = libc::proc_listallpids(pids.as_mut_ptr().cast(), (capacity * 4) as i32).max(0) as usize;
            for pid in pids.into_iter().take(count) {
                let mut info: libc::proc_bsdinfo = std::mem::zeroed();
                let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
                if libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) == size && info.pbi_uid == user {
                    children.entry(info.pbi_ppid as i32).or_default().push(pid);
                }
            }
        }
        children
    }

    /// CPU time used (nanoseconds) and physical footprint (bytes).
    #[allow(deprecated)] // libc points at the `mach2` crate for the timebase; one call isn't worth a dependency.
    pub fn usage(pid: i32) -> Option<(u64, u64)> {
        // SAFETY: both calls fill a struct of the type their flavor names.
        unsafe {
            let mut info: libc::rusage_info_v2 = std::mem::zeroed();
            if libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V2, (&mut info as *mut libc::rusage_info_v2).cast()) != 0 {
                return None;
            }
            // Times are in Mach ticks, which are not nanoseconds on Apple silicon.
            let mut timebase = libc::mach_timebase_info { numer: 1, denom: 1 };
            libc::mach_timebase_info(&mut timebase);
            let ticks = info.ri_user_time + info.ri_system_time;
            Some((ticks * timebase.numer as u64 / timebase.denom.max(1) as u64, info.ri_phys_footprint))
        }
    }

    /// The TCP ports each of `pids` listens on.
    // shortcut: asks `lsof` (the libc crate lacks the socket structs libproc fills, which the
    // Swift core reads), off the main loop; Linux, the target, reads /proc. Port to
    // `proc_pidfdinfo` if the Rust core is ever shipped on macOS.
    pub fn listening_ports(pids: &[i32]) -> HashMap<i32, Vec<ListeningPort>> {
        let mut result: HashMap<i32, Vec<ListeningPort>> = HashMap::new();
        let list = pids.iter().map(i32::to_string).collect::<Vec<_>>().join(",");
        let Ok(output) = std::process::Command::new("/usr/sbin/lsof").args(["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", &list, "-Fpn"]).stderr(std::process::Stdio::null()).output() else { return result };
        let mut pid = 0;
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if let Some(owner) = line.strip_prefix('p') {
                pid = owner.parse().unwrap_or(0);
            } else if let Some((host, port)) = line.strip_prefix('n').and_then(|name| name.rsplit_once(':')) {
                if let Ok(port) = port.parse::<i64>() {
                    result.entry(pid).or_default().push(ListeningPort { port, exposed: !(host.starts_with("127.") || host == "[::1]") });
                }
            }
        }
        result
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod system {
    use std::collections::HashMap;

    use super::ListeningPort;

    pub fn children_by_parent() -> HashMap<i32, Vec<i32>> {
        HashMap::new()
    }
    pub fn usage(_pid: i32) -> Option<(u64, u64)> {
        None
    }
    pub fn listening_ports(_pids: &[i32]) -> HashMap<i32, Vec<ListeningPort>> {
        HashMap::new()
    }
}
