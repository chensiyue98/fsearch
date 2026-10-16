//! Stable metadata ordering with bounded memory for paged search results.
use crate::Found;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::os::unix::ffi::OsStrExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchSort { NameAsc, NameDesc, Newest, Oldest, Largest, Smallest }

impl SearchSort {
    pub fn parse(value: &str) -> Result<Option<Self>, String> {
        Ok(match value {
            "relevance" => None,
            "name_asc" => Some(Self::NameAsc), "name_desc" => Some(Self::NameDesc),
            "newest" => Some(Self::Newest), "oldest" => Some(Self::Oldest),
            "largest" => Some(Self::Largest), "smallest" => Some(Self::Smallest),
            _ => return Err(format!("unknown sort {value}")),
        })
    }

    pub fn compare(self, a: &Found, b: &Found) -> Ordering {
        let name = || {
            let name = |f: &Found| f.path.file_name().unwrap_or_default().as_bytes().to_ascii_lowercase();
            name(a).cmp(&name(b))
        };
        self.compare_named(a, b, name)
    }

    fn compare_named(self, a: &Found, b: &Found, name: impl FnOnce() -> Ordering) -> Ordering {
        let order = match self {
            Self::NameAsc => name(), Self::NameDesc => name().reverse(),
            Self::Newest => b.mtime.cmp(&a.mtime), Self::Oldest => a.mtime.cmp(&b.mtime),
            Self::Largest => b.size.cmp(&a.size), Self::Smallest => a.size.cmp(&b.size),
        };
        order.then_with(|| a.path.cmp(&b.path))
    }
}

struct Ranked { hit: Found, name: Vec<u8>, sort: SearchSort }
impl PartialEq for Ranked { fn eq(&self, other: &Self) -> bool { self.cmp(other) == Ordering::Equal } }
impl Eq for Ranked {}
impl PartialOrd for Ranked { fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.cmp(other)) } }
impl Ord for Ranked { fn cmp(&self, other: &Self) -> Ordering { self.sort.compare_named(&self.hit, &other.hit, || self.name.cmp(&other.name)) } }

pub struct TopResults { heap: BinaryHeap<Ranked>, limit: usize, sort: SearchSort }
impl TopResults {
    pub fn new(limit: usize, sort: SearchSort) -> Self { Self { heap: BinaryHeap::new(), limit, sort } }
    pub fn push(&mut self, hit: Found) {
        if self.limit == 0 { return; }
        let name = if matches!(self.sort, SearchSort::NameAsc | SearchSort::NameDesc) {
            hit.path.file_name().unwrap_or_default().as_bytes().to_ascii_lowercase()
        } else { Vec::new() };
        let ranked = Ranked { hit, name, sort: self.sort };
        if self.heap.len() < self.limit { self.heap.push(ranked); }
        else if ranked.cmp(self.heap.peek().unwrap()).is_lt() { *self.heap.peek_mut().unwrap() = ranked; }
    }
    pub fn finish(self) -> Vec<Found> { self.heap.into_sorted_vec().into_iter().map(|x| x.hit).collect() }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_top_results_keep_global_extremes_and_stable_ties() {
        for sort in [SearchSort::NameAsc, SearchSort::NameDesc, SearchSort::Newest, SearchSort::Oldest, SearchSort::Largest, SearchSort::Smallest] {
            let mut top = TopResults::new(3, sort);
            let mut all = Vec::new();
            for i in (0..110).rev() {
                let hit = || Found { path: format!("/folder/{i:03}.txt").into(), kind: 0, size: i % 3, mtime: (i % 5) as u32, score: 0 };
                top.push(hit());
                all.push(hit());
            }
            all.sort_by(|a, b| sort.compare(a, b));
            assert_eq!(top.finish().iter().map(|f| &f.path).collect::<Vec<_>>(), all[..3].iter().map(|f| &f.path).collect::<Vec<_>>());
        }
    }
}
