//! Input broadcast: copies what reaches the leader's wire to each follower.
//!
//! Dart owns the leader, the follow switches and broadcast on/off, and pushes
//! the resulting snapshot through `set_snapshot`. An empty follower list means
//! off or paused; Rust never derives either.

use super::{
    add_lock_modes_modifiers, is_letter_key_4_lock_modes, is_modifier, is_numpad_key,
    legacy_keyboard_mode, map_keyboard_mode, parse_add_lock_modes_modifiers,
    shortcuts::send_windows_menu_ctrl, translate_keyboard_mode,
};
use base::message_proto::{KeyEvent, KeyboardMode};
use hbb_common::{log, SessionID};
use rdev::{Event, EventType, Key};
use std::{collections::HashMap, sync::Mutex};

lazy_static::lazy_static! {
    static ref BROADCAST: Mutex<Broadcast> = Default::default();
}

trait Peer {
    /// As `Session::peer_platform` reports it, e.g. "Windows" or "Mac OS".
    fn platform(&self) -> String;
    fn toggle_option(&self, name: &str) -> bool;
    fn send_key(&self, event: &KeyEvent);
}

struct Target {
    session: crate::flutter::FlutterSession,
}

impl Peer for Target {
    fn platform(&self) -> String {
        self.session.peer_platform()
    }

    fn toggle_option(&self, name: &str) -> bool {
        self.session.get_toggle_option(name.to_owned())
    }

    fn send_key(&self, event: &KeyEvent) {
        self.session.send_key_event(event);
    }
}

fn lookup(id: &SessionID) -> Option<Target> {
    crate::flutter::sessions::get_session_by_session_id(id).map(|session| Target { session })
}

/// What a follower was sent down and has not been sent up yet.
#[derive(Default)]
struct Held {
    keys: HashMap<Key, (Event, KeyboardMode)>,
}

impl Held {
    fn release(self, peer: &impl Peer) {
        let platform = peer.platform();
        for (key, (event, mode)) in self.keys {
            send_release(peer, &platform, key, event, mode);
        }
    }
}

#[derive(Default)]
struct Broadcast {
    /// `None` while broadcast is off or paused.
    leader: Option<SessionID>,
    followers: Vec<(SessionID, Held)>,
}

impl Broadcast {
    /// A follower that leaves gets a release for everything it holds. One that
    /// joins gets nothing until the leader's next event.
    fn set<P: Peer>(
        &mut self,
        leader: SessionID,
        followers: &[SessionID],
        lookup: impl Fn(&SessionID) -> Option<P>,
    ) {
        let mut new: Vec<SessionID> = Vec::new();
        for id in followers {
            if *id != leader && !new.contains(id) {
                new.push(*id);
            }
        }
        let same_leader = self.leader == Some(leader);
        let mut kept = HashMap::new();
        for (id, held) in std::mem::take(&mut self.followers) {
            if same_leader && new.contains(&id) {
                kept.insert(id, held);
            } else if let Some(peer) = lookup(&id) {
                held.release(&peer);
            }
        }
        self.leader = (!new.is_empty()).then_some(leader);
        self.followers = new
            .into_iter()
            .map(|id| {
                let held = kept.remove(&id).unwrap_or_default();
                (id, held)
            })
            .collect();
    }

    fn on_key<P: Peer>(
        &mut self,
        source: &SessionID,
        event: &Event,
        mode: KeyboardMode,
        lock_modes: Option<i32>,
        lookup: impl Fn(&SessionID) -> Option<P>,
    ) {
        if self.leader.as_ref() != Some(source) {
            return;
        }
        for (id, held) in &mut self.followers {
            let Some(peer) = lookup(id) else {
                // Its peer resets its own input when the connection drops.
                *held = Held::default();
                continue;
            };
            if peer.toggle_option("view-only") {
                continue;
            }
            let send = match event.event_type {
                EventType::KeyPress(key) => {
                    held.keys.insert(key, (event.clone(), mode));
                    true
                }
                EventType::KeyRelease(key) => held.keys.remove(&key).is_some(),
                _ => false,
            };
            if send {
                for key_event in encode(&peer.platform(), event, mode, lock_modes) {
                    peer.send_key(&key_event);
                }
            }
        }
    }

    /// Mirrors `shortcuts::release_remote_keys` for each follower: a consumed
    /// chord releases the modifiers early, with the same Ctrl tap that keeps a
    /// lone Alt or Meta from opening a Windows menu.
    fn release_modifiers<P: Peer>(
        &mut self,
        source: &SessionID,
        lookup: impl Fn(&SessionID) -> Option<P>,
    ) {
        if self.leader.as_ref() != Some(source) {
            return;
        }
        for (id, held) in &mut self.followers {
            let Some(peer) = lookup(id) else {
                *held = Held::default();
                continue;
            };
            if peer.toggle_option("view-only") {
                continue;
            }
            let modifiers: Vec<Key> = held
                .keys
                .keys()
                .filter(|k| is_modifier(k))
                .copied()
                .collect();
            if modifiers.is_empty() {
                continue;
            }
            let platform = peer.platform();
            let swap_ctrl_cmd = peer.toggle_option("allow_swap_key");
            let neutralize_menu = platform == "Windows"
                && modifiers.iter().all(|key| {
                    matches!(key, Key::Alt | Key::AltGr)
                        || (swap_ctrl_cmd && matches!(key, Key::ControlLeft | Key::ControlRight))
                        || (!swap_ctrl_cmd && matches!(key, Key::MetaLeft | Key::MetaRight))
                });
            let send = |key_event: &KeyEvent| peer.send_key(key_event);
            if neutralize_menu {
                send_windows_menu_ctrl(true, swap_ctrl_cmd, &send);
            }
            for key in modifiers {
                if let Some((event, mode)) = held.keys.remove(&key) {
                    send_release(&peer, &platform, key, event, mode);
                }
            }
            if neutralize_menu {
                send_windows_menu_ctrl(false, swap_ctrl_cmd, &send);
            }
        }
    }
}

fn send_release(peer: &impl Peer, platform: &str, key: Key, mut event: Event, mode: KeyboardMode) {
    event.event_type = EventType::KeyRelease(key);
    for key_event in encode(platform, &event, mode, None) {
        peer.send_key(&key_event);
    }
}

/// `event_to_key_events` without its writes to `MODIFIERS_STATE` and
/// `TO_RELEASE`. Those hold the leader's physical keys: the leader's own send
/// already wrote them, and a release sent to a leaving follower must not
/// clear them while the user still holds the key.
fn encode(
    platform: &str,
    event: &Event,
    mode: KeyboardMode,
    lock_modes: Option<i32>,
) -> Vec<KeyEvent> {
    let mut peer = platform.to_lowercase();
    peer.retain(|c| !c.is_whitespace());
    let mut key_event = KeyEvent::new();
    key_event.mode = mode.into();
    let mut key_events = match mode {
        KeyboardMode::Map => map_keyboard_mode(&peer, event, key_event),
        KeyboardMode::Translate => translate_keyboard_mode(&peer, event, key_event),
        _ => legacy_keyboard_mode(event, key_event),
    };
    let is_numpad_key = is_numpad_key(event);
    if mode != KeyboardMode::Translate || is_numpad_key {
        let is_letter_key = is_letter_key_4_lock_modes(event);
        for key_event in &mut key_events {
            if let Some(lock_modes) = lock_modes {
                parse_add_lock_modes_modifiers(key_event, lock_modes, is_numpad_key, is_letter_key);
            } else {
                add_lock_modes_modifiers(key_event, is_numpad_key, is_letter_key);
            }
        }
    }
    key_events
}

/// `followers` is a JSON array of session id strings; `[]` turns broadcast off.
pub fn set_snapshot(leader: SessionID, followers: &str) {
    let parsed = serde_json::from_str::<Vec<String>>(followers)
        .map_err(|e| e.to_string())
        .and_then(|ids| {
            ids.iter()
                .map(|id| id.parse::<SessionID>().map_err(|e| e.to_string()))
                .collect::<Result<Vec<_>, _>>()
        });
    let followers = parsed.unwrap_or_else(|e| {
        log::error!("Invalid input broadcast followers {followers:?}: {e}");
        Vec::new()
    });
    BROADCAST.lock().unwrap().set(leader, &followers, lookup);
}

/// `source` is `None` on the keyboard hook path, which sends to the current session.
pub fn on_key_event(
    source: Option<&SessionID>,
    event: &Event,
    mode: KeyboardMode,
    lock_modes: Option<i32>,
) {
    let mut broadcast = BROADCAST.lock().unwrap();
    if broadcast.leader.is_none() {
        return;
    }
    let resolved;
    let source = match source {
        Some(id) => id,
        None => {
            resolved = crate::flutter::get_cur_session_id();
            &resolved
        }
    };
    broadcast.on_key(source, event, mode, lock_modes, lookup);
}

pub fn on_release_modifiers(source: &SessionID) {
    let mut broadcast = BROADCAST.lock().unwrap();
    if broadcast.leader.is_none() {
        return;
    }
    broadcast.release_modifiers(source, lookup);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, rc::Rc};

    const LEADER: SessionID = SessionID::from_u128(1);
    const WIN: SessionID = SessionID::from_u128(2);
    const LINUX: SessionID = SessionID::from_u128(3);

    #[derive(Clone)]
    struct FakePeer {
        platform: &'static str,
        keys: Rc<RefCell<Vec<KeyEvent>>>,
    }

    impl Peer for FakePeer {
        fn platform(&self) -> String {
            self.platform.to_owned()
        }

        fn toggle_option(&self, _name: &str) -> bool {
            false
        }

        fn send_key(&self, event: &KeyEvent) {
            self.keys.borrow_mut().push(event.clone());
        }
    }

    struct Peers(HashMap<SessionID, FakePeer>);

    impl Peers {
        fn new() -> Self {
            let peer = |platform| FakePeer {
                platform,
                keys: Default::default(),
            };
            Self(HashMap::from([
                (WIN, peer("Windows")),
                (LINUX, peer("Linux")),
            ]))
        }

        fn lookup(&self) -> impl Fn(&SessionID) -> Option<FakePeer> + '_ {
            move |id: &SessionID| self.0.get(id).cloned()
        }

        /// The keys sent to `id` since the last call, as `(chr, down)`.
        fn take_keys(&self, id: SessionID) -> Vec<(u32, bool)> {
            self.0[&id]
                .keys
                .borrow_mut()
                .drain(..)
                .map(|e| (e.chr(), e.down))
                .collect()
        }
    }

    fn key(key: Key, down: bool) -> Event {
        Event {
            time: std::time::SystemTime::now(),
            unicode: None,
            platform_code: rdev::win_code_from_key(key).unwrap_or_default(),
            position_code: rdev::win_scancode_from_key(key).unwrap_or_default(),
            event_type: if down {
                EventType::KeyPress(key)
            } else {
                EventType::KeyRelease(key)
            },
            usb_hid: 0,
            extra_data: 0,
        }
    }

    /// The map-mode key code `platform` expects for `key`.
    fn code(platform: SessionID, key: Key) -> u32 {
        let scancode = rdev::win_scancode_from_key(key).unwrap_or_default();
        if platform == WIN {
            scancode
        } else {
            rdev::win_scancode_to_linux_code(scancode).unwrap_or_default() as u32
        }
    }

    fn leader_key(broadcast: &mut Broadcast, peers: &Peers, k: Key, down: bool) {
        broadcast.on_key(
            &LEADER,
            &key(k, down),
            KeyboardMode::Map,
            Some(0),
            peers.lookup(),
        );
    }

    #[test]
    fn leader_keys_reach_each_follower_encoded_for_its_platform() {
        let peers = Peers::new();
        let mut broadcast = Broadcast::default();
        broadcast.set(LEADER, &[WIN, LINUX], peers.lookup());
        leader_key(&mut broadcast, &peers, Key::ShiftLeft, true);
        leader_key(&mut broadcast, &peers, Key::KeyW, true);
        leader_key(&mut broadcast, &peers, Key::KeyW, false);
        leader_key(&mut broadcast, &peers, Key::ShiftLeft, false);

        for follower in [WIN, LINUX] {
            let shift = code(follower, Key::ShiftLeft);
            let w = code(follower, Key::KeyW);
            assert_ne!(w, 0);
            assert_eq!(
                peers.take_keys(follower),
                vec![(shift, true), (w, true), (w, false), (shift, false)],
                "follower {follower}"
            );
        }
    }

    #[test]
    fn dropped_follower_gets_one_release_for_a_held_key() {
        let peers = Peers::new();
        let mut broadcast = Broadcast::default();
        broadcast.set(LEADER, &[WIN, LINUX], peers.lookup());
        leader_key(&mut broadcast, &peers, Key::KeyW, true);
        peers.take_keys(WIN);
        peers.take_keys(LINUX);

        broadcast.set(LEADER, &[LINUX], peers.lookup());
        assert_eq!(peers.take_keys(WIN), vec![(code(WIN, Key::KeyW), false)]);
        assert_eq!(peers.take_keys(LINUX), vec![]);

        leader_key(&mut broadcast, &peers, Key::KeyW, false);
        assert_eq!(peers.take_keys(WIN), vec![]);
        assert_eq!(
            peers.take_keys(LINUX),
            vec![(code(LINUX, Key::KeyW), false)]
        );
    }

    #[test]
    fn follower_added_while_a_key_is_held_gets_nothing_until_the_next_event() {
        let peers = Peers::new();
        let mut broadcast = Broadcast::default();
        broadcast.set(LEADER, &[WIN], peers.lookup());
        leader_key(&mut broadcast, &peers, Key::KeyW, true);

        broadcast.set(LEADER, &[WIN, LINUX], peers.lookup());
        assert_eq!(peers.take_keys(LINUX), vec![]);
        leader_key(&mut broadcast, &peers, Key::KeyW, false);
        assert_eq!(peers.take_keys(LINUX), vec![]);
        let w = code(WIN, Key::KeyW);
        assert_eq!(peers.take_keys(WIN), vec![(w, true), (w, false)]);

        leader_key(&mut broadcast, &peers, Key::KeyA, true);
        assert_eq!(peers.take_keys(LINUX), vec![(code(LINUX, Key::KeyA), true)]);
    }
}
