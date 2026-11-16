//! What the core's machine is using, for `subscribeHost`. No Swift counterpart: the Mac's own
//! core doesn't report its machine.

use std::ffi::CString;

use crate::core_protocol::HostStats;
use crate::data_folder;

/// Samples the machine. CPU use is measured between two samples, so the first one covers the
/// time since the sampler was made.
pub struct HostSampler {
    /// Processor ticks so far: idle, and all of them.
    previous: (u64, u64),
}

impl Default for HostSampler {
    fn default() -> Self {
        Self { previous: cpu_ticks() }
    }
}

impl HostSampler {
    pub fn sample(&mut self) -> HostStats {
        let ticks = cpu_ticks();
        let (idle, total) = (ticks.0.saturating_sub(self.previous.0), ticks.1.saturating_sub(self.previous.1));
        self.previous = ticks;
        let cpu = if total == 0 { 0.0 } else { (1.0 - idle as f64 / total as f64).clamp(0.0, 1.0) };
        let (memory_used, memory_total) = memory();
        let (disk_used, disk_total) = disk();
        let mut load = [0.0f64; 1];
        // SAFETY: getloadavg writes at most one double into `load`.
        unsafe { libc::getloadavg(load.as_mut_ptr(), 1) };
        // SAFETY: sysconf only reads a number.
        let cores = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) }.max(1) as i64;
        HostStats { cpu, memory_used, memory_total, disk_used, disk_total, load: load[0], cores }
    }
}

/// Used and total bytes of the volume the home folder is on. Used is what the user can't
/// write to: everything but the blocks available to them.
fn disk() -> (u64, u64) {
    let Ok(home) = CString::new(data_folder::home_directory().into_os_string().into_encoded_bytes()) else { return (0, 0) };
    // SAFETY: an all-zero statvfs is valid, and statvfs fills it from a NUL-terminated path.
    unsafe {
        let mut volume: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(home.as_ptr(), &mut volume) != 0 {
            return (0, 0);
        }
        let block = volume.f_frsize as u64;
        let total = volume.f_blocks as u64 * block;
        (total.saturating_sub(volume.f_bavail as u64 * block), total)
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn cpu_ticks() -> (u64, u64) {
    // "cpu  user nice system idle iowait irq softirq steal guest guest_nice"; the guests are
    // already counted in user and nice.
    let stat = std::fs::read_to_string("/proc/stat").unwrap_or_default();
    let ticks: Vec<u64> = stat.lines().next().unwrap_or_default().split_whitespace().skip(1).take(8).filter_map(|field| field.parse().ok()).collect();
    (ticks.iter().skip(3).take(2).sum(), ticks.iter().sum())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn memory() -> (u64, u64) {
    let info = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let field = |name: &str| info.lines().find_map(|line| line.strip_prefix(name)?.split_whitespace().next()?.parse::<u64>().ok()).unwrap_or(0) * 1024;
    let total = field("MemTotal:");
    (total.saturating_sub(field("MemAvailable:")), total)
}

#[cfg(target_os = "macos")]
#[allow(deprecated)] // libc points these Mach calls at the `mach2` crate; not worth a dependency.
fn cpu_ticks() -> (u64, u64) {
    // SAFETY: host_statistics fills `info`, whose size in integers `count` gives.
    unsafe {
        let mut info: libc::host_cpu_load_info = std::mem::zeroed();
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        if libc::host_statistics(libc::mach_host_self(), libc::HOST_CPU_LOAD_INFO, (&mut info as *mut libc::host_cpu_load_info).cast(), &mut count) != 0 {
            return (0, 0);
        }
        (info.cpu_ticks[libc::CPU_STATE_IDLE as usize] as u64, info.cpu_ticks.iter().map(|ticks| *ticks as u64).sum())
    }
}

#[cfg(target_os = "macos")]
#[allow(deprecated)]
fn memory() -> (u64, u64) {
    // SAFETY: both calls fill a value of the size they are told.
    unsafe {
        let mut total: u64 = 0;
        let mut size = std::mem::size_of::<u64>();
        libc::sysctlbyname(c"hw.memsize".as_ptr(), (&mut total as *mut u64).cast(), &mut size, std::ptr::null_mut(), 0);
        let mut info: libc::vm_statistics64 = std::mem::zeroed();
        let mut count = libc::HOST_VM_INFO64_COUNT;
        if libc::host_statistics64(libc::mach_host_self(), libc::HOST_VM_INFO64, (&mut info as *mut libc::vm_statistics64).cast(), &mut count) != 0 {
            return (0, total);
        }
        // What Activity Monitor calls memory used: app (active), wired and compressed.
        let pages = info.active_count as u64 + info.wire_count as u64 + info.compressor_page_count as u64;
        ((pages * libc::vm_page_size as u64).min(total), total)
    }
}
